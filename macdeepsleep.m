#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

extern int IOBluetoothPreferenceGetControllerPowerState(void);
extern void IOBluetoothPreferenceSetControllerPowerState(int state);

#define VERSION "2.1.0"
#define STATE_FILE "/var/tmp/macdeepsleep.state"

static io_connect_t g_root_port;
static int g_wifi_on  = -1;
static int g_bt_on    = -1;
static int g_awdl_on  = -1;

// ─── Wi-Fi (CoreWLAN) ────────────────────────────────────────────

static CWInterface *get_wifi_interface(void) {
    return [[CWWiFiClient sharedWiFiClient] interface];
}

static int get_wifi_state(void) {
    CWInterface *iface = get_wifi_interface();
    if (!iface) return -1;
    return iface.powerOn ? 1 : 0;
}

static void set_wifi(BOOL on) {
    CWInterface *iface = get_wifi_interface();
    if (!iface) return;
    NSError *err = nil;
    if (![iface setPower:on error:&err]) {
        fprintf(stderr, "macdeepsleep: Wi-Fi setPower:%d failed: %s\n",
                on, err ? [[err localizedDescription] UTF8String] : "unknown");
    }
}

// ─── Bluetooth (IOBluetooth private API) ─────────────────────────

static int get_bt_state(void) {
    return IOBluetoothPreferenceGetControllerPowerState();
}

static void set_bt(int on) {
    IOBluetoothPreferenceSetControllerPowerState(on ? 1 : 0);
}

// ─── AWDL (BSD ioctl) ────────────────────────────────────────────

static int get_awdl_state(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "awdl0", IFNAMSIZ - 1);
    int rc = ioctl(fd, SIOCGIFFLAGS, &ifr);
    close(fd);
    if (rc < 0) return -1;
    return (ifr.ifr_flags & IFF_UP) ? 1 : 0;
}

static void set_awdl(int on) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, "awdl0", IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) { close(fd); return; }
    if (on) {
        ifr.ifr_flags |= IFF_UP;
    } else {
        ifr.ifr_flags &= ~IFF_UP;
    }
    if (ioctl(fd, SIOCSIFFLAGS, &ifr) < 0) {
        fprintf(stderr, "macdeepsleep: ioctl SIOCSIFFLAGS awdl0 failed\n");
    }
    close(fd);
}

// ─── 状态持久化 ──────────────────────────────────────────────────

static void save_state(int wifi, int bt, int awdl) {
    FILE *fp = fopen(STATE_FILE, "w");
    if (fp) {
        fprintf(fp, "%d %d %d\n", wifi, bt, awdl);
        fclose(fp);
    }
}

static int load_state(int *wifi, int *bt, int *awdl) {
    FILE *fp = fopen(STATE_FILE, "r");
    if (!fp) return 0;
    int ret = (fscanf(fp, "%d %d %d", wifi, bt, awdl) == 3) ? 1 : 0;
    fclose(fp);
    return ret;
}

static void clear_state(void) {
    unlink(STATE_FILE);
}

// ─── 恢复网络 ────────────────────────────────────────────────────

static void restore(int wifi, int bt, int awdl) {
    fprintf(stderr, "macdeepsleep: restoring wifi=%d bt=%d awdl=%d\n",
            wifi, bt, awdl);
    @autoreleasepool {
        if (wifi == 1)  set_wifi(YES);
        if (bt == 1)    set_bt(1);
        if (awdl == 1)  set_awdl(1);
    }
}

// ─── IOKit 电源回调 ──────────────────────────────────────────────

static void callback(void *ref __unused, io_service_t srv __unused,
                     natural_t msg, void *arg)
{
    switch (msg) {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(g_root_port, (long)arg);
            break;

        case kIOMessageSystemWillSleep:
            @autoreleasepool {
                if (g_wifi_on == -1) g_wifi_on = get_wifi_state();
                if (g_bt_on   == -1) g_bt_on   = get_bt_state();
                if (g_awdl_on == -1) g_awdl_on = get_awdl_state();

                fprintf(stderr, "macdeepsleep: sleep — wifi=%d bt=%d awdl=%d\n",
                        g_wifi_on, g_bt_on, g_awdl_on);

                save_state(g_wifi_on, g_bt_on, g_awdl_on);

                if (g_wifi_on == 1)  set_wifi(NO);
                if (g_bt_on   == 1)  set_bt(0);
                if (g_awdl_on == 1)  set_awdl(0);
            }
            IOAllowPowerChange(g_root_port, (long)arg);
            break;

        case kIOMessageSystemHasPoweredOn: {
            int fw = -1, fb = -1, fa = -1;
            if (load_state(&fw, &fb, &fa)) {
                restore(fw, fb, fa);
                clear_state();
            } else if (g_wifi_on != -1 || g_bt_on != -1 || g_awdl_on != -1) {
                restore(g_wifi_on, g_bt_on, g_awdl_on);
            }
            g_wifi_on = g_bt_on = g_awdl_on = -1;
            break;
        }
    }
}

// ─── main ────────────────────────────────────────────────────────

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && (strcmp(argv[1], "--version") == 0 ||
                         strcmp(argv[1], "-v") == 0)) {
            printf("macdeepsleep %s\n", VERSION);
            return 0;
        }

        /* 启动时检查是否有未恢复的状态（异常断电/崩溃） */
        {
            int fw = -1, fb = -1, fa = -1;
            if (load_state(&fw, &fb, &fa)) {
                fprintf(stderr, "macdeepsleep: recovering from crash/reboot\n");
                restore(fw, fb, fa);
                clear_state();
            }
        }

        IONotificationPortRef port;
        io_object_t notifier;

        g_root_port = IORegisterForSystemPower(NULL, &port, callback, &notifier);
        if (g_root_port == IO_OBJECT_NULL) {
            fprintf(stderr, "macdeepsleep: IORegisterForSystemPower failed\n");
            return 1;
        }

        CWInterface *iface = get_wifi_interface();
        fprintf(stderr, "macdeepsleep: started (v%s, iface=%s)\n",
                VERSION, iface ? [iface.interfaceName UTF8String] : "none");

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
            IONotificationPortGetRunLoopSource(port),
            kCFRunLoopDefaultMode);
        CFRunLoopRun();
    }
    return 0;
}
