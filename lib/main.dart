import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:convert';

// Platform-specific imports
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    if (dart.library.html) 'dart:async';

// Web stubs
class BluetoothDeviceStub {
  final String name;
  final String id;

  BluetoothDeviceStub({this.name = '', this.id = ''});

  Future<void> connect({Duration? timeout, bool autoConnect = false}) async {}
  Future<void> disconnect() async {}
}

class ScanResultStub {
  final BluetoothDeviceStub device;
  ScanResultStub(this.device);
}

// Platform-specific types
final class BluetoothDeviceType {
  static Type get type => kIsWeb ? BluetoothDeviceStub : BluetoothDevice;
}

final class ScanResultType {
  static Type get type => kIsWeb ? ScanResultStub : ScanResult;
}

// Add a mapping for BLE UUIDs
const Map<String, String> bleCharacteristicUuids = {
  'SOC': '761d55b6-ca3b-4730-b609-ca17bbeb486c',
  'TEMP1': '91e8d31f-03f2-40eb-962e-58b7826aee12',
  'TEMP2': 'e7805646-255c-4737-835e-634a90bf8aa6',
  'PRES': '3b470a66-8f2c-41f6-85fa-e424e056e3b1',
  'RPS': '0d02a718-1ca5-45a5-920e-56daf0328dee',
  'CMD': 'ad1c9cca-f2a8-4a5d-8cbe-6626ebb7ab0a',
};

Future<bool> ensureLocationPermission(BuildContext context) async {
  final status = await Permission.location.status;
  if (status.isGranted) return true;
  if (status.isPermanentlyDenied) {
    // Show dialog to open app settings
    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Location Permission Required'),
          content: const Text(
              'Location permission is required to scan for Bluetooth devices. Please enable it in app settings.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
    return false;
  }
  // Request permission
  final result = await Permission.location.request();
  if (result.isGranted) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Location permission is required for Bluetooth scanning.')),
    );
  }
  return false;
}

Future<bool> ensureBluetoothOn(BuildContext context) async {
  if (!(await FlutterBluePlus.isOn)) {
    print('Bluetooth is OFF, showing dialog');
    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Bluetooth Required'),
          content: const Text('Bluetooth is currently OFF. This will open your phone\'s Bluetooth settings. Please turn on Bluetooth and return to the app to scan for devices.'),
          actions: [
            TextButton(
              onPressed: () {
                print('User chose to open Bluetooth settings');
                Navigator.of(ctx).pop();
                FlutterBluePlus.turnOn();
              },
              child: const Text('Open Settings'),
            ),
            TextButton(
              onPressed: () {
                print('User cancelled Bluetooth enable dialog');
                Navigator.of(ctx).pop();
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
    return false;
  }
  print('Bluetooth is ON, proceeding to scan');
  return true;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb) {
    try {
      await Permission.bluetoothScan.request();
      await Permission.bluetoothConnect.request();
      await Permission.location.request();
    } catch (e) {
      debugPrint('Error requesting permissions: $e');
    }
  }

  runApp(
    ChangeNotifierProvider(
      create: (_) => BluetoothStateProvider(),
      child: const MyApp(),
    ),
  );
}

class BluetoothStateProvider extends ChangeNotifier {
  bool _isScanning = false;
  dynamic _connectedDevice;
  final List<dynamic> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  bool get isScanning => _isScanning;
  dynamic get connectedDevice => _connectedDevice;
  List<dynamic> get scanResults => List.unmodifiable(_scanResults);

  Future<void> startScan([BuildContext? context]) async {
    debugPrint('Scan button pressed');
    if (kIsWeb) {
      debugPrint('Bluetooth scanning is not supported on web platform');
      return;
    }

    if (_isScanning) return;

    // Check location permission before scanning
    if (context != null) {
      final granted = await ensureLocationPermission(context);
      if (!granted) return;
      final btOn = await ensureBluetoothOn(context);
      if (!btOn) return;
    }

    try {
      _scanResults.clear();
      _isScanning = true;
      notifyListeners();

      // Cancel previous subscription if exists
      await _scanSubscription?.cancel();

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        print('Scan results: \\n' + results.map((r) => r.device.platformName).join(', '));
        _scanResults
          ..clear()
          ..addAll(results);
        notifyListeners();
      });

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      debugPrint('Error scanning: $e');
    } finally {
      _isScanning = false;
      notifyListeners();
      try {
        await FlutterBluePlus.stopScan();
      } catch (e) {
        debugPrint('Error stopping scan: $e');
      }
    }
  }

  Future<void> connectToDevice(dynamic device) async {
    if (kIsWeb) return;

    try {
      // Cancel previous connection subscription
      await _connectionSubscription?.cancel();

      final bluetoothDevice = device as BluetoothDevice;

      // Listen to connection state changes
      _connectionSubscription = bluetoothDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null;
          notifyListeners();
        }
      });

      // Connect to device
      await bluetoothDevice.connect();
      _connectedDevice = bluetoothDevice;
      notifyListeners();
    } catch (e) {
      debugPrint('Error connecting to device: $e');
    }
  }

  Future<void> disconnectDevice() async {
    if (_connectedDevice == null || kIsWeb) return;

    try {
      if (!kIsWeb) {
        await (_connectedDevice as BluetoothDevice).disconnect();
      }
      _connectedDevice = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Error disconnecting: $e');
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}

class BluetoothDataProvider extends ChangeNotifier {
  Map<String, String> _lastReadings = {};

  String? getLastReading(String deviceName, String measurementType) {
    return _lastReadings['${deviceName}_$measurementType'];
  }

  Future<String> fetchReading(String deviceName, String measurementType) async {
    // Simulate fetching data from the device
    await Future.delayed(const Duration(seconds: 1));
    String reading = '';

    switch (measurementType) {
      case 'SPO2':
        reading = '${95 + (DateTime.now().millisecondsSinceEpoch % 5)}%';
        break;
      case 'LungPressure':
        reading = '${10 + (DateTime.now().millisecondsSinceEpoch % 6)} cmH2O';
        break;
      case 'LungCapacity':
        reading = '${3 + (DateTime.now().millisecondsSinceEpoch % 3)} L';
        break;
    }

    _lastReadings['${deviceName}_$measurementType'] = reading;
    notifyListeners();
    return reading;
  }
}

// Reusable widget for the logo
class MedantrikLogo extends StatelessWidget {
  final double height;
  final bool showText;
  final bool isWhite;
  final bool isBackground;

  const MedantrikLogo({
    super.key,
    this.height = 40,
    this.showText = false,
    this.isWhite = false,
    this.isBackground = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          isBackground
              ? 'assets/images/medantrik_logo.png'
              : 'assets/images/medantrik_logo1.png',
          height: height,
          errorBuilder: (_, __, ___) => Icon(
            Icons.medical_services,
            size: height,
            color: isWhite ? Colors.white : null,
          ),
        ),
        if (showText) ...[
          const SizedBox(width: 8),
          Text(
            'MEDANTRIK',
            style: TextStyle(
              fontSize: height * 0.6,
              fontWeight: FontWeight.bold,
              color: isWhite ? Colors.white : null,
            ),
          ),
        ],
      ],
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medantrix App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class BluetoothHomePage extends StatelessWidget {
  const BluetoothHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final bluetoothState = Provider.of<BluetoothStateProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            MedantrikLogo(height: 32, showText: true),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (kIsWeb)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Bluetooth functionality is not available on web platform. Please use the mobile app for Bluetooth features.',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              )
            else ...[
              // Connected device section
              if (bluetoothState.connectedDevice != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const Text(
                          'Connected Device',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          kIsWeb
                              ? (bluetoothState.connectedDevice
                                      as BluetoothDeviceStub)
                                  .name
                              : (bluetoothState.connectedDevice
                                      as BluetoothDevice)
                                  .platformName,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: bluetoothState.disconnectDevice,
                          icon: const Icon(Icons.bluetooth_disabled),
                          label: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Scan button
              ElevatedButton.icon(
                onPressed: bluetoothState.isScanning
                    ? null
                    : () => bluetoothState.startScan(context),
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(bluetoothState.isScanning
                    ? 'Scanning...'
                    : 'Scan for Devices'),
              ),
              const SizedBox(height: 16),

              // Scan results
              const Text(
                'Available Devices',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: bluetoothState.scanResults.isEmpty
                    ? const Center(
                        child: Text(
                          'No devices found',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: bluetoothState.scanResults.length,
                        itemBuilder: (context, index) {
                          final result = bluetoothState.scanResults[index];
                          final device = kIsWeb
                              ? (result as ScanResultStub).device
                              : (result as ScanResult).device;
                          return Card(
                            child: ListTile(
                              leading: const Icon(Icons.bluetooth),
                              title: Text(kIsWeb
                                  ? (device as BluetoothDeviceStub).name
                                  : (device as BluetoothDevice).platformName),
                              subtitle: Text(kIsWeb
                                  ? (device as BluetoothDeviceStub).id
                                  : (device as BluetoothDevice)
                                      .remoteId
                                      .toString()),
                              trailing: ElevatedButton(
                                onPressed: () =>
                                    bluetoothState.connectToDevice(device),
                                child: const Text('Connect'),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  void _login() {
    // Validate that all fields are filled
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your username')),
      );
      return;
    }
    
    if (_emailController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email')),
      );
      return;
    }
    
    if (_passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your password')),
      );
      return;
    }
    
    // Basic email validation
    if (!_emailController.text.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email address')),
      );
      return;
    }
    
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => HomePage(
          userName: _nameController.text.trim(),
          userEmail: _emailController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background logo
          Positioned.fill(
            child: Opacity(
              opacity: 0.15,
              child: FittedBox(
                fit: BoxFit.cover,
                child: MedantrikLogo(height: 400, isBackground: true),
              ),
            ),
          ),
          // Login content
          Center(
            child: Card(
              elevation: 8,
              margin: const EdgeInsets.all(32.0),
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MedantrikLogo(height: 80),
                    const SizedBox(height: 16),
                    const Text(
                      'Welcome to Medantrik',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please login to continue',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person),
                        hintText: 'Enter your username',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.email),
                        hintText: 'Enter your email address',
                      ),
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.lock),
                        hintText: 'Enter your password',
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: _login,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 48, vertical: 16),
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                      child: const Text('Login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  final String userName;
  final String userEmail;

  const HomePage({
    super.key,
    required this.userName,
    required this.userEmail,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: MedantrikLogo(height: 56),
        ),
        centerTitle: true,
        toolbarHeight: 80,
        actions: [
          Consumer<BluetoothStateProvider>(
            builder: (_, state, __) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: state.connectedDevice != null
                    ? Colors.blue.withOpacity(0.1)
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                icon: Icon(
                  Icons.bluetooth,
                  color: state.connectedDevice != null ? Colors.blue : null,
                ),
                onPressed: () {
                  state.startScan();
                  showDialog(
                    context: context,
                    barrierDismissible: true,
                    builder: (_) => const BluetoothDialog(),
                  );
                },
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const CircleAvatar(child: Icon(Icons.person)),
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(userName,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(userEmail, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: const Text('Logout'),
                onTap: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: const Center(
                child: MedantrikLogo(height: 80, isWhite: true),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.home),
              title: const Text('Home'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {},
            ),
          ],
        ),
      ),
      body: Consumer<BluetoothStateProvider>(
        builder: (_, state, __) => Stack(
          children: [
            // Background logo
            Positioned.fill(
              child: Opacity(
                opacity: 0.15,
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: MedantrikLogo(height: 400, isBackground: true),
                ),
              ),
            ),
            // Main content
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  Text(
                    'WELCOME $userName, THANK YOU FOR JOINING MEDANTRIK',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 24),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  const Text('Connect to your health devices',
                      style:
                          TextStyle(fontSize: 20, fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 32),
                  if (state.connectedDevice != null)
                    Card(
                      elevation: 4,
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        title: Text(
                          state.connectedDevice!.platformName.isNotEmpty
                              ? state.connectedDevice!.platformName
                              : "Unnamed Device",
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w500),
                        ),
                        subtitle:
                            Text(state.connectedDevice!.remoteId.toString()),
                        trailing: const Icon(Icons.check_circle,
                            color: Colors.green, size: 28),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DevicePage(
                                  deviceName: state.connectedDevice!
                                          .platformName.isNotEmpty
                                      ? state.connectedDevice!.platformName
                                      : "Unnamed Device"),
                            ),
                          );
                        },
                      ),
                    )
                  else
                    const Card(
                      elevation: 4,
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No device connected. Click the Bluetooth icon to connect.',
                          style: TextStyle(fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  const Spacer(),
                  const Text('Your health is our concern 💙',
                      style:
                          TextStyle(fontSize: 18, fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BluetoothDialog extends StatelessWidget {
  const BluetoothDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<BluetoothStateProvider>(
      builder: (_, state, __) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Available Devices',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('CLOSE'),
                  ),
                ],
              ),
              const Divider(),
              if (state.isScanning)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                )
              else if (state.scanResults.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No devices found'),
                )
              else
                ...state.scanResults.map((result) => ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(result.device.platformName.isNotEmpty
                          ? result.device.platformName
                          : "(Unnamed Device)"),
                      subtitle: Text(result.device.remoteId.toString()),
                      trailing: Text('${result.rssi} dBm'),
                      onTap: () async {
                        Navigator.pop(context);
                        await state.connectToDevice(result.device);
                      },
                    )),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: state.isScanning ? null : () => state.startScan(),
                icon: const Icon(Icons.search),
                label:
                    Text(state.isScanning ? 'Scanning...' : 'Scan for Devices'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> readBleCharacteristic(BluetoothDevice device, String charType) async {
  try {
    final services = await device.discoverServices();
    for (var service in services) {
      for (var characteristic in service.characteristics) {
        if (characteristic.uuid.toString().toLowerCase() == bleCharacteristicUuids[charType]?.toLowerCase()) {
          final value = await characteristic.read();
          return utf8.decode(value);
        }
      }
    }
    return 'Not found';
  } catch (e) {
    return 'Error: $e';
  }
}

Future<void> writeBleCommand(BluetoothDevice device, int command) async {
  try {
    final services = await device.discoverServices();
    for (var service in services) {
      for (var characteristic in service.characteristics) {
        if (characteristic.uuid.toString().toLowerCase() == bleCharacteristicUuids['CMD']?.toLowerCase()) {
          await characteristic.write(utf8.encode(command.toString()));
          return;
        }
      }
    }
  } catch (e) {
    debugPrint('Error writing command: $e');
  }
}

class DevicePage extends StatelessWidget {
  final String deviceName;
  const DevicePage({super.key, required this.deviceName});

  Widget _buildMeasurementButton({
    required BuildContext context,
    required String type,
    required String buttonText,
  }) {
    final dataProvider = Provider.of<BluetoothDataProvider>(context);
    final lastReading = dataProvider.getLastReading(deviceName, type);
    final bluetoothState = Provider.of<BluetoothStateProvider>(context, listen: false);

    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: () async {
              String reading;
              if (bluetoothState.connectedDevice != null && !kIsWeb) {
                reading = await readBleCharacteristic(bluetoothState.connectedDevice, type);
              } else {
                reading = await dataProvider.fetchReading(deviceName, type);
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('New $type reading: $reading')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
            child: Text(buttonText, style: const TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(width: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            lastReading ?? 'No data',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bluetoothState = Provider.of<BluetoothStateProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: MedantrikLogo(height: 56),
        ),
        centerTitle: true,
        toolbarHeight: 80,
      ),
      body: Stack(
        children: [
          // Background logo
          Positioned.fill(
            child: Opacity(
              opacity: 0.15,
              child: FittedBox(
                fit: BoxFit.cover,
                child: MedantrikLogo(height: 400, isBackground: true),
              ),
            ),
          ),
          // Main content
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  deviceName,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        _buildMeasurementButton(
                          context: context,
                          type: 'TEMP1',
                          buttonText: 'Get Temperature 1',
                        ),
                        const SizedBox(height: 16),
                        _buildMeasurementButton(
                          context: context,
                          type: 'SOC',
                          buttonText: 'Get Battery SOC',
                        ),
                        const SizedBox(height: 16),
                        _buildMeasurementButton(
                          context: context,
                          type: 'PRES',
                          buttonText: 'Get Atmospheric Pressure',
                        ),
                        const SizedBox(height: 16),
                        _buildMeasurementButton(
                          context: context,
                          type: 'RPS',
                          buttonText: 'Get Heart Beat (RPS)',
                        ),
                        const SizedBox(height: 16),
                        _buildMeasurementButton(
                          context: context,
                          type: 'TEMP2',
                          buttonText: 'Get Temperature 2',
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: bluetoothState.connectedDevice == null || kIsWeb
                                    ? null
                                    : () => writeBleCommand(bluetoothState.connectedDevice, 2),
                                child: const Text('Start Test'),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: bluetoothState.connectedDevice == null || kIsWeb
                                    ? null
                                    : () => writeBleCommand(bluetoothState.connectedDevice, 3),
                                child: const Text('Stop Test'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
