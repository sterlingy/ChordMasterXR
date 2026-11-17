package org.chordmasterxr.midi;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.midi.MidiDevice;
import android.media.midi.MidiDeviceInfo;
import android.media.midi.MidiManager;
import android.media.midi.MidiOutputPort;
import android.media.midi.MidiReceiver;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import android.util.Log;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Reads MIDI input on Android (Godot has no Android MIDI driver).
 *
 * - USB MIDI devices and already-connected Bluetooth MIDI devices are found
 *   through android.media.midi.MidiManager and opened automatically,
 *   including hot-plug.
 * - Bluetooth LE MIDI keyboards must be opened by an app before Android
 *   exposes them: scanBluetooth() scans for the BLE MIDI service and opens
 *   every keyboard it finds.
 *
 * Every channel message is sent to Godot as the signal
 *   midi_message(status: int, data1: int, data2: int)
 * which the Midi autoload treats exactly like desktop MIDI input.
 */
public class ChordMasterMidiPlugin extends GodotPlugin {
    private static final String TAG = "ChordMasterMidi";
    private static final ParcelUuid BLE_MIDI_SERVICE =
            ParcelUuid.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700");
    private static final int PERMISSION_REQUEST = 7311;

    private static final SignalInfo SIG_MESSAGE =
            new SignalInfo("midi_message", Integer.class, Integer.class, Integer.class);
    private static final SignalInfo SIG_DEVICES =
            new SignalInfo("devices_changed", String.class);
    private static final SignalInfo SIG_BT_STATUS =
            new SignalInfo("bluetooth_status", String.class);

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private MidiManager midiManager;
    private final Map<Integer, MidiDevice> openDevices = new HashMap<>();
    private final Map<Integer, List<MidiOutputPort>> openPorts = new HashMap<>();
    private final Map<Integer, String> deviceNames = new HashMap<>();
    private final Set<String> bleOpening = new HashSet<>();
    private boolean started = false;

    private BluetoothLeScanner bleScanner;
    private ScanCallback bleCallback;
    private boolean pendingScan = false;
    private int pendingScanSeconds = 15;

    public ChordMasterMidiPlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "ChordMasterMidi";
    }

    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> s = new HashSet<>();
        s.add(SIG_MESSAGE);
        s.add(SIG_DEVICES);
        s.add(SIG_BT_STATUS);
        return s;
    }

    // ------------------------------------------------------------------
    // API used from GDScript
    // ------------------------------------------------------------------

    /** True if this device supports MIDI at all. */
    @UsedByGodot
    public boolean isSupported() {
        Context ctx = getContext();
        return ctx != null && ctx.getPackageManager().hasSystemFeature(PackageManager.FEATURE_MIDI);
    }

    /** Opens every MIDI device that has output ports and watches for hot-plug. */
    @UsedByGodot
    public void start() {
        mainHandler.post(() -> {
            if (started) {
                return;
            }
            Context ctx = getContext();
            if (ctx == null || !isSupported()) {
                Log.w(TAG, "MIDI not supported on this device");
                return;
            }
            midiManager = (MidiManager) ctx.getSystemService(Context.MIDI_SERVICE);
            if (midiManager == null) {
                return;
            }
            started = true;
            midiManager.registerDeviceCallback(deviceCallback, mainHandler);
            for (MidiDeviceInfo info : midiManager.getDevices()) {
                openDevice(info);
            }
            // Bluetooth MIDI keyboards already paired with the headset don't
            // advertise, so a scan can't find them: open them directly.
            if (hasBluetoothPermissions()) {
                openBondedMidiDevices(false);
            }
            notifyDevices();
        });
    }

    /** Newline-separated names of the devices currently open. */
    @UsedByGodot
    public String getDeviceNames() {
        synchronized (deviceNames) {
            List<String> names = new ArrayList<>(deviceNames.values());
            Collections.sort(names);
            return String.join("\n", names);
        }
    }

    /** Scans for Bluetooth LE MIDI keyboards for `seconds` and opens any found. */
    @UsedByGodot
    public void scanBluetooth(int seconds) {
        mainHandler.post(() -> {
            if (!hasBluetoothPermissions()) {
                pendingScan = true;
                pendingScanSeconds = seconds;
                requestBluetoothPermissions();
                return;
            }
            startBleScan(seconds);
        });
    }

    @UsedByGodot
    public void stopBluetoothScan() {
        mainHandler.post(this::stopBleScan);
    }

    // ------------------------------------------------------------------
    // Device handling
    // ------------------------------------------------------------------

    private final MidiManager.DeviceCallback deviceCallback = new MidiManager.DeviceCallback() {
        @Override
        public void onDeviceAdded(MidiDeviceInfo info) {
            openDevice(info);
        }

        @Override
        public void onDeviceRemoved(MidiDeviceInfo info) {
            closeDevice(info.getId());
            notifyDevices();
        }
    };

    private static String nameOf(MidiDeviceInfo info) {
        Bundle p = info.getProperties();
        String name = p.getString(MidiDeviceInfo.PROPERTY_NAME);
        if (name == null || name.isEmpty()) {
            name = p.getString(MidiDeviceInfo.PROPERTY_PRODUCT);
        }
        if (name == null || name.isEmpty()) {
            name = "MIDI device " + info.getId();
        }
        if (info.getType() == MidiDeviceInfo.TYPE_BLUETOOTH) {
            name += " (Bluetooth)";
        }
        return name;
    }

    private void openDevice(MidiDeviceInfo info) {
        // "Output" ports are where a keyboard sends notes *to us*.
        if (info.getOutputPortCount() == 0 || openDevices.containsKey(info.getId())) {
            return;
        }
        midiManager.openDevice(info, device -> {
            if (device == null) {
                Log.w(TAG, "Could not open " + nameOf(info));
                return;
            }
            attach(device);
        }, mainHandler);
    }

    private void attach(MidiDevice device) {
        MidiDeviceInfo info = device.getInfo();
        int id = info.getId();
        if (openDevices.containsKey(id)) {
            closeQuietly(device);
            return;
        }
        List<MidiOutputPort> ports = new ArrayList<>();
        for (int i = 0; i < info.getOutputPortCount(); i++) {
            MidiOutputPort port = device.openOutputPort(i);
            if (port != null) {
                port.connect(new Parser());
                ports.add(port);
            }
        }
        openDevices.put(id, device);
        openPorts.put(id, ports);
        synchronized (deviceNames) {
            deviceNames.put(id, nameOf(info));
        }
        Log.i(TAG, "Opened " + nameOf(info) + " (" + ports.size() + " ports)");
        notifyDevices();
    }

    private void closeDevice(int id) {
        List<MidiOutputPort> ports = openPorts.remove(id);
        if (ports != null) {
            for (MidiOutputPort p : ports) {
                try {
                    p.close();
                } catch (IOException ignored) {
                }
            }
        }
        MidiDevice d = openDevices.remove(id);
        if (d != null) {
            closeQuietly(d);
        }
        synchronized (deviceNames) {
            deviceNames.remove(id);
        }
    }

    private static void closeQuietly(MidiDevice d) {
        try {
            d.close();
        } catch (IOException ignored) {
        }
    }

    private void notifyDevices() {
        final String names = getDeviceNames();
        runOnRenderThread(() -> emitSignal(SIG_DEVICES.getName(), names));
    }

    // ------------------------------------------------------------------
    // MIDI byte-stream parser (running status, ignores SysEx and realtime)
    // ------------------------------------------------------------------

    private class Parser extends MidiReceiver {
        private int status = 0;
        private final int[] data = new int[2];
        private int count = 0;
        private boolean inSysex = false;

        @Override
        public void onSend(byte[] msg, int offset, int len, long timestamp) {
            for (int i = offset; i < offset + len; i++) {
                int b = msg[i] & 0xFF;
                if (b >= 0xF8) {
                    continue; // realtime (clock, active sensing...) – ignore
                }
                if (b == 0xF0) {
                    inSysex = true;
                    continue;
                }
                if (b == 0xF7) {
                    inSysex = false;
                    continue;
                }
                if (inSysex) {
                    continue;
                }
                if (b >= 0x80) {
                    if (b >= 0xF0) {
                        status = 0; // system common – not needed
                    } else {
                        status = b;
                    }
                    count = 0;
                    continue;
                }
                if (status == 0) {
                    continue;
                }
                data[count++] = b;
                int needed = dataBytes(status);
                if (count >= needed) {
                    final int s = status;
                    final int d1 = data[0];
                    final int d2 = needed > 1 ? data[1] : 0;
                    count = 0; // keep status (running status)
                    runOnRenderThread(() -> emitSignal(SIG_MESSAGE.getName(), s, d1, d2));
                }
            }
        }

        private int dataBytes(int s) {
            int type = s & 0xF0;
            return (type == 0xC0 || type == 0xD0) ? 1 : 2;
        }
    }

    // ------------------------------------------------------------------
    // Bluetooth LE MIDI
    // ------------------------------------------------------------------

    private String[] bluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT};
        }
        return new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }

    private boolean hasBluetoothPermissions() {
        Activity a = getActivity();
        if (a == null) {
            return false;
        }
        for (String p : bluetoothPermissions()) {
            if (a.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) {
                return false;
            }
        }
        return true;
    }

    private void requestBluetoothPermissions() {
        Activity a = getActivity();
        if (a != null) {
            status("Asking for Bluetooth permission…");
            a.requestPermissions(bluetoothPermissions(), PERMISSION_REQUEST);
        }
    }

    @Override
    public void onMainRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode != PERMISSION_REQUEST || !pendingScan) {
            return;
        }
        pendingScan = false;
        if (hasBluetoothPermissions()) {
            startBleScan(pendingScanSeconds);
        } else {
            status("Bluetooth permission denied");
        }
    }

    /**
     * Opens paired (bonded) Bluetooth LE devices as MIDI devices.
     * Devices that advertise the BLE MIDI service UUID are always tried; with
     * {@code includeUnknown}, so are LE devices whose services aren't cached
     * yet (only on an explicit user request, since it briefly connects).
     */
    private int openBondedMidiDevices(boolean includeUnknown) {
        Context ctx = getContext();
        BluetoothManager bm = ctx == null ? null : (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null || !adapter.isEnabled() || midiManager == null) {
            return 0;
        }
        int tried = 0;
        try {
            for (BluetoothDevice d : adapter.getBondedDevices()) {
                int type = d.getType();
                if (type != BluetoothDevice.DEVICE_TYPE_LE && type != BluetoothDevice.DEVICE_TYPE_DUAL) {
                    continue;
                }
                ParcelUuid[] uuids = d.getUuids();
                boolean isMidi = false;
                if (uuids != null) {
                    for (ParcelUuid u : uuids) {
                        if (BLE_MIDI_SERVICE.equals(u)) {
                            isMidi = true;
                            break;
                        }
                    }
                }
                String name = d.getName();
                boolean nameLooksMidi = name != null && name.toLowerCase().matches(".*(midi|key|piano|synth|xkey).*");
                if (isMidi || (includeUnknown && (uuids == null || uuids.length == 0 || nameLooksMidi))) {
                    onBleFound(d);
                    tried++;
                }
            }
        } catch (SecurityException e) {
            Log.w(TAG, "No permission to list paired devices");
        }
        return tried;
    }

    private void startBleScan(int seconds) {
        if (!started) {
            start();
        }
        int paired = openBondedMidiDevices(true);
        if (paired > 0) {
            status("Trying " + paired + " paired Bluetooth device(s)…");
        }
        Context ctx = getContext();
        BluetoothManager bm = ctx == null ? null : (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            status("Bluetooth is off");
            return;
        }
        bleScanner = adapter.getBluetoothLeScanner();
        if (bleScanner == null) {
            status("Bluetooth LE not available");
            return;
        }
        stopBleScan();
        bleCallback = new ScanCallback() {
            @Override
            public void onScanResult(int callbackType, ScanResult result) {
                onBleFound(result.getDevice());
            }

            @Override
            public void onBatchScanResults(List<ScanResult> results) {
                for (ScanResult r : results) {
                    onBleFound(r.getDevice());
                }
            }

            @Override
            public void onScanFailed(int errorCode) {
                status("Bluetooth scan failed (" + errorCode + ")");
            }
        };
        List<ScanFilter> filters = new ArrayList<>();
        filters.add(new ScanFilter.Builder().setServiceUuid(BLE_MIDI_SERVICE).build());
        ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build();
        try {
            bleScanner.startScan(filters, settings, bleCallback);
        } catch (SecurityException e) {
            status("Bluetooth permission missing");
            return;
        }
        status("Scanning for Bluetooth MIDI keyboards… (put yours in pairing mode)");
        mainHandler.postDelayed(() -> {
            if (bleCallback != null) {
                stopBleScan();
                status("Scan finished");
            }
        }, seconds * 1000L);
    }

    private void stopBleScan() {
        if (bleScanner != null && bleCallback != null) {
            try {
                bleScanner.stopScan(bleCallback);
            } catch (SecurityException ignored) {
            }
        }
        bleCallback = null;
    }

    private void onBleFound(BluetoothDevice device) {
        String addr = device.getAddress();
        if (bleOpening.contains(addr)) {
            return;
        }
        bleOpening.add(addr);
        String name;
        try {
            name = device.getName();
        } catch (SecurityException e) {
            name = null;
        }
        final String label = name != null ? name : addr;
        status("Connecting to " + label + "…");
        midiManager.openBluetoothDevice(device, midiDevice -> {
            bleOpening.remove(addr);
            if (midiDevice == null) {
                status("Could not connect to " + label);
                return;
            }
            attach(midiDevice);
            status("Connected: " + label);
        }, mainHandler);
    }

    private void status(String text) {
        Log.i(TAG, text);
        runOnRenderThread(() -> emitSignal(SIG_BT_STATUS.getName(), text));
    }

    @Override
    public void onMainDestroy() {
        stopBleScan();
        for (Integer id : new ArrayList<>(openDevices.keySet())) {
            closeDevice(id);
        }
        if (midiManager != null && started) {
            midiManager.unregisterDeviceCallback(deviceCallback);
        }
    }
}
