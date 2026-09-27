#!/usr/bin/env python3
import fcntl
import json
import subprocess
import sys
import time
from pathlib import Path

BATTERY_LEVEL = "00002a19-0000-1000-8000-00805f9b34fb"
USER_DESC = "00002901-0000-1000-8000-00805f9b34fb"
KEYBOARD_APPEARANCE = 961
STATE_PATH = Path.home() / ".local/state/omarchy/split-keyboard-battery.json"
# A lithium gauge can tick up by a point or two without a charge.
CHARGE_JUMP = 3
MAX_RATE_PER_HOUR = 30


def busctl_json(args):
    result = subprocess.run(
        ["busctl", "--json=short", *args],
        capture_output=True,
        text=True,
        timeout=8,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "busctl failed")
    if not result.stdout.strip():
        return None
    return json.loads(result.stdout)


def prop(props, name):
    value = props.get(name)
    if value is None:
        return None
    return value.get("data")


def read_bytes(path, interface):
    payload = busctl_json(
        ["call", "org.bluez", path, interface, "ReadValue", "a{sv}", "0"]
    )
    if not payload or payload.get("type") != "ay":
        return b""
    data = payload.get("data") or []
    # busctl --json=short wraps an ay value in an extra array.
    if len(data) == 1 and isinstance(data[0], list):
        data = data[0]
    return bytes(data)


def device_path(object_path):
    marker = "/service"
    index = object_path.find(marker)
    if index == -1:
        return ""
    return object_path[:index]


def load_locked(handle):
    handle.seek(0)
    raw = handle.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def store_locked(handle, state):
    handle.seek(0)
    handle.write(json.dumps(state))
    handle.truncate()


def format_remaining(hours):
    if hours < 1.5:
        return str(max(1, round(hours * 60))) + "m"
    if hours < 48:
        return str(round(hours)) + "h"
    days = hours / 24
    if days > 60:
        return ">60d"
    if days < 10 and abs(days - round(days)) >= 0.15:
        return f"{days:.1f}d"
    return str(round(days)) + "d"


def remaining_label(percent, rate):
    if not rate or rate <= 0:
        return None
    return format_remaining(percent / rate)


def estimate_half(label, percent, now, state):
    halves = state.setdefault("halves", {})
    half = halves.setdefault(label, {})
    samples = half.setdefault("samples", [])
    # Older state stored only the latest percent, which moved the baseline
    # forward on every drop and left nothing to measure.
    if not samples and half.get("anchorPercent") is not None:
        samples.append({"t": half.get("anchorTime") or now, "p": half["anchorPercent"]})

    if samples and percent < samples[-1]["p"] - 10 and (now - samples[-1]["t"]) < 300:
        return remaining_label(samples[-1]["p"], half.get("ratePerHour"))

    if samples and percent >= min(sample["p"] for sample in samples[-8:]) + CHARGE_JUMP:
        samples.clear()

    if not samples or samples[-1]["p"] != percent:
        samples.append({"t": now, "p": percent})
    if len(samples) > 400:
        del samples[:-400]

    baseline = None
    window_start = now - 14 * 24 * 3600
    for sample in samples:
        if sample["t"] < window_start:
            continue
        if sample["p"] > percent:
            baseline = sample
            break
    if baseline is None:
        half.pop("ratePerHour", None)
        return None
    elapsed_hours = (now - baseline["t"]) / 3600
    if elapsed_hours <= 0:
        return None
    rate = (baseline["p"] - percent) / elapsed_hours
    if not 0 < rate <= MAX_RATE_PER_HOUR:
        return None
    half["ratePerHour"] = rate
    return remaining_label(percent, rate)


def record_estimates(readings, now):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.touch(exist_ok=True)
    estimates = {}
    with STATE_PATH.open("r+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        state = load_locked(handle)
        for label, percent in readings:
            estimates[label] = estimate_half(label, percent, now, state)
        store_locked(handle, state)
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    return estimates


def peripheral_index(label):
    prefix = "Peripheral "
    if not label.startswith(prefix):
        return None
    suffix = label[len(prefix):]
    if not suffix.isdigit():
        return None
    return int(suffix)


def main():
    managed = busctl_json(
        ["call", "org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects"]
    )
    objects = managed["data"][0]

    descriptions = {}
    batteries = []
    for path, ifaces in objects.items():
        descriptor = ifaces.get("org.bluez.GattDescriptor1")
        if descriptor and prop(descriptor, "UUID") == USER_DESC:
            characteristic = prop(descriptor, "Characteristic")
            if characteristic:
                descriptions.setdefault(characteristic, path)
            continue
        characteristic = ifaces.get("org.bluez.GattCharacteristic1")
        if characteristic and prop(characteristic, "UUID") == BATTERY_LEVEL:
            owner = device_path(path)
            if owner:
                batteries.append((owner, path))

    now = time.time()
    keyboards = []
    for path, ifaces in objects.items():
        device = ifaces.get("org.bluez.Device1")
        if not device or not prop(device, "Connected"):
            continue
        icon = prop(device, "Icon")
        appearance = prop(device, "Appearance")
        if icon != "input-keyboard" and appearance != KEYBOARD_APPEARANCE:
            continue
        halves = []
        for owner, characteristic in batteries:
            if owner != path:
                continue
            level = read_bytes(characteristic, "org.bluez.GattCharacteristic1")
            if not level:
                continue
            label = "Left"
            order = (0, 0)
            descriptor = descriptions.get(characteristic)
            if descriptor:
                text = read_bytes(descriptor, "org.bluez.GattDescriptor1").decode("utf-8", "replace").strip("\x00").strip()
                index = peripheral_index(text)
                if index is not None:
                    label = text
                    order = (1, index)
            halves.append({"label": label, "percent": level[0], "order": order})
        if not halves:
            continue
        halves.sort(key=lambda half: half["order"])
        peripheral_count = sum(1 for half in halves if half["order"][0] == 1)
        named = []
        for half in halves:
            label = half["label"]
            if peripheral_count == 1 and half["order"][0] == 1:
                label = "Right"
            named.append((label, half["percent"]))
        estimates = record_estimates(named, now)
        cleaned = []
        for label, percent in named:
            entry = {"label": label, "percent": percent}
            if estimates.get(label):
                entry["estimate"] = estimates[label]
            cleaned.append(entry)
        keyboards.append({
            "name": prop(device, "Alias") or prop(device, "Name") or "Keyboard",
            "halves": cleaned,
        })

    json.dump({"connected": bool(keyboards), "keyboards": keyboards}, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        json.dump({"connected": False, "error": str(error), "keyboards": []}, sys.stdout)
