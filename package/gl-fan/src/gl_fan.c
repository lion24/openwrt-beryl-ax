/*
 * gl_fan - PID fan controller for the GL.iNet Beryl AX / GL-MT3000.
 *
 * Clean-room reimplementation of the vendor /usr/bin/gl_fan daemon,
 * recovered from the stock firmware binary. It samples the CPU
 * temperature from a thermal sysfs node and drives the thermal cooling
 * device PWM with an incremental PID loop.
 *
 * Sysfs nodes:
 *   read  CPU temp      : -T path (default thermal_zone0/temp)
 *   write fan PWM       : /sys/class/thermal/cooling_device0/cur_state
 *   read  fan tach (-s) : /sys/class/fan/fan_speed            [vendor kernel]
 *   read  PWM ceiling   : /proc/gl-hw-info/fan_pwm_max         [vendor kernel]
 *
 * The last two nodes are provided by the GL.iNet vendor kernel driver
 * (gl_fan_driver) and are absent on vanilla OpenWrt; the PWM ceiling
 * then falls back to 120 and the -s tachometer read simply fails.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#define COOLING_PATH    "/sys/class/thermal/cooling_device0/cur_state"
#define FAN_SPEED_PATH  "/sys/class/fan/fan_speed"
#define FAN_PWM_MAX_PATH "/proc/gl-hw-info/fan_pwm_max"
#define DEFAULT_TEMP_SYSFS "/sys/devices/virtual/thermal/thermal_zone0/temp"

#define DEF_DIV     10
#define DEF_TARGET  75
#define DEF_KP      10
#define DEF_KI      2
#define DEF_KD      10

#define PWM_MAX_FALLBACK 120
#define INTEGRAL_CEIL    120   /* hard cap on the integral accumulator   */
#define WINDUP_RESET     -4    /* dump integral once temp is this far below target */
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

/* Trigger and print the fan tachometer reading (-s). */
static int get_fan_speed(void)
{
	char buf[128];
	struct stat st;

	if (stat(FAN_SPEED_PATH, &st) != 0)
		return -2;

	if (write_file(FAN_SPEED_PATH, "refresh", 7) != 1)
		return -2;

	sleep(2);

	memset(buf, 0, sizeof(buf));
	read_file(FAN_SPEED_PATH, buf);
	buf[sizeof(buf) - 1] = '\0';
	puts(buf);

	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s [option]\n"
		"          -T sysfs         # temperature sysfs path, default is %s\n"
		"          -D div         # temperature divide, default is %d\n"
		"          -t temperature   # expected CPU temperature, default is %d\n"
		"          -p proportion    # Proportion parameter in PID algorithm, default is %d\n"
		"          -i integration   # integration parameter in PID algorithm, default is %d\n"
		"          -d differential  # differential parameter in PID algorithm, default is %d\n"
		"          -s               # print fan speed\n"
		"          -v               # verbose\n",
		prog, g_temp_path, g_div, DEF_TARGET, DEF_KP, DEF_KI, DEF_KD);
}

int main(int argc, char **argv)
{
	int target = DEF_TARGET;
	float kp = DEF_KP, ki = DEF_KI, kd = DEF_KD;
	int pwm_max;
	struct stat st;
	int opt;

	/* PWM ceiling from the vendor node, or a safe fallback. */
	if (stat(FAN_PWM_MAX_PATH, &st) == 0) {
		char buf[128];
		memset(buf, 0, sizeof(buf));
		read_file(FAN_PWM_MAX_PATH, buf);
		pwm_max = atoi(buf);
	} else {
		pwm_max = PWM_MAX_FALLBACK;
	}

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

	set_fan_pwm(0);

	int e = 0, e1 = 0, e2 = 0;   /* error, e[-1], e[-2] */
	int integral = 0;
	float prev_out = 0.0f;

	for (;;) {
		int temp;

		if (get_cpu_temp(&temp) != 0) {
			/* keep the rolling error window intact, skip this update */
			e = e1;
			e1 = e2;
			goto nap;
		}

		e = temp - target;

		/* integral accumulator, clamped to [0, INTEGRAL_CEIL] with
		 * anti-windup reset once we drop well below target */
		int cand = integral + e;
		if (cand > INTEGRAL_CEIL)
			integral = INTEGRAL_CEIL;
		else if (cand < 0)
			integral = 0;
		else if (e < WINDUP_RESET)
			integral = 0;
		else
			integral = cand;

		/* incremental PID: derivative on the 2nd difference of error */
		float d = (float)(e - 2 * e1 + e2);
		float u = kp * (float)e - kd * d + ki * (float)integral;

		if (u > (float)pwm_max)
			u = (float)pwm_max;
		else if (u < 0.0f)
			u = 0.0f;

		if (u != 0.0f) {
			set_fan_pwm((unsigned)u);
			prev_out = u;
		} else if (prev_out != 0.0f) {
			/* first iteration commanding "off": hold before cutting */
			sleep(SPINDOWN_HOLD);
			set_fan_pwm(0);
			prev_out = 0.0f;
		}
		/* else: already off, leave the fan alone */

nap:
		e2 = e1;
		sleep(LOOP_PERIOD);
		e1 = e;
	}

	return 0;
}
