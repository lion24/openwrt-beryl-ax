/*
 * gl_fan - PID fan controller for the GL.iNet Beryl AX / GL-MT3000.
 *
 * Clean-room reimplementation of the vendor /usr/bin/gl_fan daemon. It
 * samples the CPU temperature from a thermal sysfs node and drives the
 * thermal cooling device with a standard positional PID loop: proportional
 * on the temperature error, integral with anti-windup, derivative on the
 * error's first difference. Error e = temp - target, so a hotter CPU
 * raises the output.
 *
 * On stock OpenWrt the kernel thermal governor already controls this fan,
 * so the service ships disabled. When enabled, the daemon switches the
 * thermal zone to the "user_space" governor on start (so the kernel stops
 * overriding the cooling state it writes) and restores "step_wise" on exit,
 * including on a fatal signal, so the kernel always regains control.
 *
 * Sysfs nodes:
 *   read  CPU temp     : -T path (default thermal_zone0/temp, millidegrees)
 *   write fan state    : /sys/class/thermal/cooling_device0/cur_state
 *   read  state ceiling: /sys/class/thermal/cooling_device0/max_state
 *   read  fan tach (-s): /sys/class/hwmon/hwmonN/fan1_input
 *
 * Standard thermal sysfs reports millidegrees, hence the default divisor of
 * 1000. cur_state must stay within [0, max_state], so the output ceiling is
 * the cooling device's max_state (falling back to the vendor gl-hw-info
 * node, then a constant).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <glob.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>

#define COOLING_PATH    "/sys/class/thermal/cooling_device0/cur_state"
#define MAX_STATE_PATH  "/sys/class/thermal/cooling_device0/max_state"
#define POLICY_PATH     "/sys/class/thermal/thermal_zone0/policy"
#define FAN_SPEED_GLOB  "/sys/class/hwmon/hwmon*/fan1_input"
#define FAN_PWM_MAX_PATH "/proc/gl-hw-info/fan_pwm_max"
#define DEFAULT_TEMP_SYSFS "/sys/devices/virtual/thermal/thermal_zone0/temp"

#define DEF_DIV     1000  /* thermal sysfs reports millidegrees Celsius */
#define DEF_TARGET  60    /* PID baseline, deg C; fan ramps above it    */
#define DEF_KP      0.1f  /* gains tuned for a coarse pwm-fan (0..3):   */
#define DEF_KI      0.0f  /* P-only curve, ~1 fan step per 10 deg C;    */
#define DEF_KD      0.0f  /* enable I/D via UCI if wanted               */

#define PWM_MAX_FALLBACK 120
#define LOOP_PERIOD      20    /* seconds between control updates         */
#define SPINDOWN_HOLD    300   /* seconds to hold before cutting the fan  */

static const char *g_temp_path = DEFAULT_TEMP_SYSFS;
static int g_div = DEF_DIV;

/* Read the first line of a file into dst (newline stripped).
 * dst must be pre-zeroed and large enough. Returns 0, or -1 if open fails. */
static int read_file(const char *path, char *dst)
{
	char *line = NULL;
	size_t n = 0;
	FILE *f = fopen(path, "r");

	if (!f)
		return -1;

	ssize_t len = getline(&line, &n, f);
	if (len != -1)
		memcpy(dst, line, len - 1);   /* drop trailing newline */

	fclose(f);
	free(line);
	return 0;
}

/* Read a small integer from a sysfs/proc file. Returns 0 if absent. */
static int read_int_file(const char *path)
{
	char buf[128];
	struct stat st;

	if (stat(path, &st) != 0)
		return 0;

	memset(buf, 0, sizeof(buf));
	read_file(path, buf);
	return atoi(buf);
}

/* Write a buffer to a file as a single fwrite item.
 * Returns 1 on success, 0 on failure (matches the vendor semantics). */
static int write_file(const char *path, const void *buf, size_t len)
{
	FILE *f = fopen(path, "w");
	int r;

	if (!f)
		return 0;

	r = fwrite(buf, len, 1, f);
	fclose(f);
	return r;
}

/* Read the CPU temperature into *out (already divided by g_div).
 * Returns 0 if the value is sane, -2 if out of range, -1 on stat failure. */
static int get_cpu_temp(int *out)
{
	char buf[128];
	struct stat st;
	int t;

	if (stat(g_temp_path, &st) != 0)
		return -1;

	memset(buf, 0, sizeof(buf));
	read_file(g_temp_path, buf);

	t = atoi(buf) / g_div;
	*out = t;

	return ((unsigned)(t - 1) < 0x95) ? 0 : -2;
}

/* Drive the cooling device PWM. Returns 0 on success, -2 otherwise. */
static int set_fan_pwm(int val)
{
	char buf[128];
	struct stat st;

	sprintf(buf, "%d\n", val & 0xff);

	if (stat(COOLING_PATH, &st) != 0)
		return -2;

	if (write_file(COOLING_PATH, buf, strlen(buf)) != 1)
		return -2;

	return 0;
}

/* Async-signal-safe: hand the thermal zone back to the kernel governor and
 * exit. Used as the handler for both graceful and fatal signals so the fan
 * never ends up in user_space with no daemon driving it. */
static void on_signal(int sig)
{
	int fd = open(POLICY_PATH, O_WRONLY);

	if (fd >= 0) {
		ssize_t n = write(fd, "step_wise\n", 10);
		(void)n;
		close(fd);
	}
	_exit(128 + sig);
}

/* Switch the thermal zone to userspace control and arrange to restore the
 * kernel governor on exit. No-op if the policy node is missing/not writable. */
static void claim_thermal_zone(void)
{
	struct sigaction sa;

	if (write_file(POLICY_PATH, "user_space\n", sizeof("user_space\n") - 1) != 1)
		return;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
}

/* Print the fan tachometer reading (-s) from the hwmon interface. */
static int get_fan_speed(void)
{
	glob_t g;
	char buf[128];
	int rc = -2;

	if (glob(FAN_SPEED_GLOB, 0, NULL, &g) != 0)
		return -2;

	if (g.gl_pathc > 0) {
		memset(buf, 0, sizeof(buf));
		read_file(g.gl_pathv[0], buf);
		buf[sizeof(buf) - 1] = '\0';
		puts(buf);
		rc = 0;
	}

	globfree(&g);
	return rc;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s [option]\n"
		"          -T sysfs         # temperature sysfs path, default is %s\n"
		"          -D div         # temperature divide, default is %d\n"
		"          -t temperature   # expected CPU temperature, default is %d\n"
		"          -p proportion    # Proportion parameter in PID algorithm, default is %g\n"
		"          -i integration   # integration parameter in PID algorithm, default is %g\n"
		"          -d differential  # differential parameter in PID algorithm, default is %g\n"
		"          -s               # print fan speed\n"
		"          -v               # verbose\n",
		prog, g_temp_path, g_div, DEF_TARGET, DEF_KP, DEF_KI, DEF_KD);
}

int main(int argc, char **argv)
{
	int target = DEF_TARGET;
	float kp = DEF_KP, ki = DEF_KI, kd = DEF_KD;
	int pwm_max;
	int opt;

	/* cur_state must stay within [0, max_state]; prefer the cooling
	 * device's own ceiling, then the vendor node, then a safe constant. */
	pwm_max = read_int_file(MAX_STATE_PATH);
	if (pwm_max <= 0)
		pwm_max = read_int_file(FAN_PWM_MAX_PATH);
	if (pwm_max <= 0)
		pwm_max = PWM_MAX_FALLBACK;

	while ((opt = getopt(argc, argv, "T:D:t:p:i:d:vs")) != -1) {
		switch (opt) {
		case 'T':
			g_temp_path = optarg;
			break;
		case 'D': {
			int d = atoi(optarg);
			g_div = (d <= 0) ? 1 : d;   /* never divide by zero */
			break;
		}
		case 't':
			target = atoi(optarg);
			break;
		case 'p':
			kp = atof(optarg);
			break;
		case 'i':
			ki = atof(optarg);
			break;
		case 'd':
			kd = atof(optarg);
			break;
		case 'v':
			break;              /* accepted, no-op (matches vendor) */
		case 's':
			get_fan_speed();
			return 0;
		default:
			usage(argv[0]);
			exit(1);
		}
	}

	claim_thermal_zone();
	set_fan_pwm(0);

	int e_prev = 0;
	int integral = 0;
	float prev_out = 0.0f;

	for (;;) {
		int temp;

		if (get_cpu_temp(&temp) != 0) {
			sleep(LOOP_PERIOD);
			continue;
		}

		int e = temp - target;   /* > 0 when hotter than target */

		/* integral with anti-windup: clamp to [0, pwm_max] so it never
		 * winds up below the floor nor past what saturates the output */
		integral += e;
		if (integral > pwm_max)
			integral = pwm_max;
		else if (integral < 0)
			integral = 0;

		/* derivative on the first difference: rising temp -> more fan */
		int derivative = e - e_prev;

		float u = kp * (float)e + ki * (float)integral + kd * (float)derivative;

		if (u > (float)pwm_max)
			u = (float)pwm_max;
		else if (u < 0.0f)
			u = 0.0f;

		if (u != 0.0f) {
			set_fan_pwm((unsigned)u);
			prev_out = u;
		} else if (prev_out != 0.0f) {
			/* first cycle commanding "off": hold before cutting */
			sleep(SPINDOWN_HOLD);
			set_fan_pwm(0);
			prev_out = 0.0f;
		}
		/* else: already off, leave the fan alone */

		e_prev = e;
		sleep(LOOP_PERIOD);
	}

	return 0;
}
