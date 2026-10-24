// batt: one line per wireless device: name, kind, battery %, charging state.
//
// Two sources:
//   UPower (system D-Bus): every battery the kernel exposes as a power_supply
//     (HID++ mice and keyboards on a Lightspeed receiver) plus the Bluetooth
//     devices BlueZ reads a battery from.
//   Logitech "Centurion" headsets (PRO X 2 LIGHTSPEED): no kernel driver reads
//     them, so batt asks the headset itself over /dev/hidraw. The exchange is
//     the one solaar does (logitech_receiver/base.py, device.py, centurion.py).
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <systemd/sd-bus.h>

#define LEN(a) (sizeof(a) / sizeof *(a))

static int found;

static void line(const char *name, const char *kind, const char *pct, const char *state)
{
    // UPower and the HID name both say "Logitech PRO X 2"; the kind column is enough
    if (!strncmp(name, "Logitech ", 9))
        name += 9;
    printf("%-20s %-8s %4s  %s\n", name, kind, pct, state);
    found++;
}


// ---- UPower ----------------------------------------------------------------

#define UPOWER "org.freedesktop.UPower"
#define UP_DEV "org.freedesktop.UPower.Device"

// UpDeviceKind, UpDeviceState, UpDeviceLevel (upower's up-types.h)
static const char *const up_kind[] = {
    "device", "charger", "battery", "ups", "monitor", "mouse", "keyboard",
    "pda", "phone", "player", "tablet", "computer", "gamepad", "pen",
    "touchpad", "modem", "network", "headset", "speakers", "headphones",
    "video", "audio", "remote", "printer", "scanner", "camera", "wearable",
    "toy", "bluetooth",
};
static const char *const up_state[] = {
    "unknown", "charging", "discharging", "empty", "full",
    "plugged, not charging", "discharging",
};
// devices that only report a coarse level, no percentage
static const char *const up_level[] = {
    [3] = "low", [4] = "critical", [6] = "normal", [7] = "high", [8] = "full",
};

static int prop(sd_bus *bus, const char *path, const char *name, char type, void *out)
{
    return sd_bus_get_property_trivial(bus, UPOWER, path, UP_DEV, name, NULL, type, out);
}

static void upower_device(sd_bus *bus, const char *path)
{
    int supply = 1, present = 0;
    uint32_t kind = 0, state = 0, level = 0;
    double pct = 0;
    char *model = NULL, num[16];

    // PowerSupply = the laptop's own battery or the charger, not a device
    if (prop(bus, path, "PowerSupply", 'b', &supply) < 0 || supply)
        return;
    if (prop(bus, path, "IsPresent", 'b', &present) < 0 || !present)
        return;
    prop(bus, path, "Type", 'u', &kind);
    prop(bus, path, "State", 'u', &state);
    prop(bus, path, "BatteryLevel", 'u', &level);
    prop(bus, path, "Percentage", 'd', &pct);
    sd_bus_get_property_string(bus, UPOWER, path, UP_DEV, "Model", NULL, &model);

    if (level < LEN(up_level) && up_level[level])
        snprintf(num, sizeof num, "%s", up_level[level]);
    else
        snprintf(num, sizeof num, "%.0f%%", pct);
    line(model && *model ? model : strrchr(path, '/') + 1,
         kind < LEN(up_kind) ? up_kind[kind] : "device", num,
         state < LEN(up_state) ? up_state[state] : "unknown");
    free(model);
}

static void from_upower(void)
{
    sd_bus *bus = NULL;
    sd_bus_message *reply = NULL;
    sd_bus_error err = SD_BUS_ERROR_NULL;
    const char *path;
    int r;

    if ((r = sd_bus_open_system(&bus)) < 0) {
        fprintf(stderr, "batt: system bus: %s\n", strerror(-r));
        return;
    }
    if (sd_bus_call_method(bus, UPOWER, "/org/freedesktop/UPower", UPOWER,
                           "EnumerateDevices", &err, &reply, "") < 0)
        fprintf(stderr, "batt: UPower: %s\n", err.message);
    else if (sd_bus_message_enter_container(reply, 'a', "o") > 0)
        while (sd_bus_message_read(reply, "o", &path) > 0)
            upower_device(bus, path);
    sd_bus_error_free(&err);
    sd_bus_message_unref(reply);
    sd_bus_unref(bus);
}


// ---- Centurion over hidraw ---------------------------------------------------
//
// Every frame is one 64-byte HID report:
//   [0x51, cpl length, flags, feature index, function << 4 | sw id, params...]
// cpl length counts flags + everything after it. It is HID++ 2.0 without the
// device-index byte: a feature call names a feature by its index on the
// device, and ROOT (index 0) function 0 maps a feature ID to that index.
//
// On the dongle the headset sits behind the CentPP bridge (feature 0x0003). A
// call to the headset is the same three-byte call wrapped in a bridge message:
//   [bridge index, 0x10 | sw id, device << 4 | len >> 8, len & 0xFF,
//    0x00, feature index, function << 4 | sw id, params...]
// The dongle ACKs it, then the answer comes back as a bridge MessageEvent
// (function 1, sw id 0) carrying the headset's reply in the same layout.

#define REPORT     0x51
#define FRAME      64
#define SWID       0x0C   // tags our calls; solaar's 0x0B, so replies never cross
#define TIMEOUT_MS 1500   // through the dongle and over the air and back

#define F_BRIDGE  0x0003
#define F_BATTERY 0x0104  // CENTURION_BATTERY_SOC

static int64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

static int send_frame(int fd, const uint8_t *msg, size_t n)
{
    uint8_t f[FRAME] = { REPORT, n + 1, 0x00 };
    memcpy(f + 3, msg, n);
    return write(fd, f, sizeof f) == (ssize_t)sizeof f ? 0 : -1;
}

// next 0x51 frame (the node also carries media keys etc.), 0 when time is up
static int read_frame(int fd, uint8_t f[FRAME], int64_t deadline)
{
    for (;;) {
        struct pollfd p = { .fd = fd, .events = POLLIN };
        int64_t left = deadline - now_ms();
        if (left <= 0 || poll(&p, 1, left) <= 0)
            return 0;
        if (read(fd, f, FRAME) >= 6 && f[0] == REPORT)
            return 1;
    }
}

// a feature call on the device the hidraw node is
static int call(int fd, uint8_t feat, uint8_t func, const uint8_t *par, size_t np,
                uint8_t *out, size_t no)
{
    uint8_t msg[2 + 8] = { feat, func << 4 | SWID }, f[FRAME];
    memcpy(msg + 2, par, np);
    if (send_frame(fd, msg, 2 + np) < 0)
        return -1;
    for (int64_t end = now_ms() + TIMEOUT_MS; read_frame(fd, f, end);) {
        if (f[3] == feat && f[4] == msg[1]) {
            memcpy(out, f + 5, no);
            return 0;
        }
        // HID++ 2.0 error: 0xFF, the call's feature and function, error code
        if (f[3] == 0xFF && f[4] == feat && f[5] == msg[1])
            return -1;
    }
    return -1;
}

// a feature call on the headset, through the dongle's bridge
static int bridge_call(int fd, uint8_t bridge, uint8_t feat, uint8_t func,
                       const uint8_t *par, size_t np, uint8_t *out, size_t no)
{
    size_t ns = 3 + np;
    uint8_t msg[4 + 3 + 8] = { bridge, 0x10 | SWID, ns >> 8 & 0x0F, ns & 0xFF,
                               0x00, feat, func << 4 | SWID }, f[FRAME];
    memcpy(msg + 7, par, np);
    if (send_frame(fd, msg, 4 + ns) < 0)
        return -1;
    for (int64_t end = now_ms() + TIMEOUT_MS; read_frame(fd, f, end);) {
        // skip the ACK (sw id ours) and headset notifications (sub cpl 0xFF)
        if (f[3] != bridge || f[4] != 0x10 || f[7] != 0x00)
            continue;
        if (f[8] == feat && f[9] == msg[6]) {
            memcpy(out, f + 10, no);
            return 0;
        }
        if (f[8] == 0xFF && f[9] == feat && f[10] == msg[6])
            return -1;
    }
    return -1;
}

// ROOT.GetFeature: the feature's index on the device, 0 = not there
static uint8_t feature(int fd, int bridge, uint16_t id)
{
    uint8_t par[2] = { id >> 8, id & 0xFF }, idx = 0;
    int r = bridge ? bridge_call(fd, bridge, 0, 0, par, 2, &idx, 1)
                   : call(fd, 0, 0, par, 2, &idx, 1);
    return r < 0 ? 0 : idx;
}

static void centurion_device(const char *dev, const char *name)
{
    static const char *const state[] = { "discharging", "charging", "charging", "full" };
    uint8_t b[3], idx, bridge;
    int fd, r = -1;
    char num[8];

    if ((fd = open(dev, O_RDWR | O_CLOEXEC)) < 0) {
        line(name, "headset", "--", errno == EACCES ? "no access to the hidraw node" : strerror(errno));
        return;
    }
    // the battery is on the node itself when the headset is on its USB cable,
    // behind the bridge when it is on the dongle
    if ((idx = feature(fd, 0, F_BATTERY)))
        r = call(fd, idx, 0, NULL, 0, b, 3);
    else if ((bridge = feature(fd, 0, F_BRIDGE)) && (idx = feature(fd, bridge, F_BATTERY)))
        r = bridge_call(fd, bridge, idx, 0, NULL, 0, b, 3);
    close(fd);

    if (r < 0) {
        line(name, "headset", "--", "off or out of range");
        return;
    }
    // reply: percent, percent again, charging state
    snprintf(num, sizeof num, "%u%%", b[0]);
    line(name, "headset", num, b[2] < LEN(state) ? state[b[2]] : "unknown");
}

// a Report ID item (tag 0x84) holding 0x51 in the report descriptor
static int has_report_id(const uint8_t *d, size_t n, uint8_t id)
{
    for (size_t i = 0; i < n;) {
        if (d[i] == 0xFE) {  // long item: data size in the next byte
            i += 3 + (i + 1 < n ? d[i + 1] : 0);
            continue;
        }
        size_t size = (d[i] & 3) == 3 ? 4 : d[i] & 3;
        if ((d[i] & 0xFC) == 0x84 && size == 1 && i + 1 < n && d[i + 1] == id)
            return 1;
        i += 1 + size;
    }
    return 0;
}

// Logitech hidraw nodes that speak Centurion
static void from_centurion(void)
{
    DIR *dir = opendir("/sys/class/hidraw");
    struct dirent *e;
    char path[320], buf[4096], dev[300];

    if (!dir)
        return;
    while ((e = readdir(dir))) {
        char name[128] = "";
        int logitech = 0;
        size_t n = 0;
        FILE *f;

        if (strncmp(e->d_name, "hidraw", 6))
            continue;
        snprintf(path, sizeof path, "/sys/class/hidraw/%s/device/uevent", e->d_name);
        if (!(f = fopen(path, "r")))
            continue;
        while (fgets(buf, sizeof buf, f)) {
            buf[strcspn(buf, "\n")] = 0;
            if (!strncmp(buf, "HID_ID=", 7) && strstr(buf, ":0000046D:"))
                logitech = 1;
            if (!strncmp(buf, "HID_NAME=", 9))
                snprintf(name, sizeof name, "%.127s", buf + 9);
        }
        fclose(f);
        if (!logitech)
            continue;

        snprintf(path, sizeof path, "/sys/class/hidraw/%s/device/report_descriptor", e->d_name);
        if ((f = fopen(path, "rb"))) {
            n = fread(buf, 1, sizeof buf, f);
            fclose(f);
        }
        if (!has_report_id((const uint8_t *)buf, n, REPORT))
            continue;
        snprintf(dev, sizeof dev, "/dev/%s", e->d_name);
        centurion_device(dev, *name ? name : e->d_name);
    }
    closedir(dir);
}


int main(int argc, char **argv)
{
    (void)argv;
    if (argc > 1) {
        fputs("usage: batt\n", stderr);
        return 2;
    }
    from_upower();
    from_centurion();
    if (!found)
        puts("no battery devices found");
    return 0;
}
