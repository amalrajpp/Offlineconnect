import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../nearby/nearby_controller.dart';
import '../../core/models/ble_models.dart';

// Enum to manage our distinct UI states
enum ConnectState { listening, connecting, success }

class KineticConnectScreen extends StatefulWidget {
  const KineticConnectScreen({super.key});

  @override
  State<KineticConnectScreen> createState() => _KineticConnectScreenState();
}

class _KineticConnectScreenState extends State<KineticConnectScreen> {
  ConnectState _currentState = ConnectState.listening;
  
  // Sensor & Stream Subscriptions
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  
  // Tuning Variables
  final double _kineticThreshold = 15.0; 
  final int _rssiThreshold = -35;
  
  // The closest node found during a bump
  String? _closestNodeId;

  // Debounce to prevent multiple bumps
  bool _isProcessingBump = false;

  @override
  void initState() {
    super.initState();
    _startSensorFusion();
  }

  void _startSensorFusion() {
    // Using userAccelerometerEventStream removes gravity automatically
    _accelSubscription = userAccelerometerEventStream().listen((UserAccelerometerEvent event) {
      if (_currentState != ConnectState.listening || _isProcessingBump) return;

      // Calculate pure kinetic magnitude
      double magnitude = sqrt(pow(event.x, 2) + pow(event.y, 2) + pow(event.z, 2));

      if (magnitude > _kineticThreshold) {
        _handleKineticBump();
      }
    });
  }

  Future<void> _handleKineticBump() async {
    _isProcessingBump = true;

    try {
      final controller = Get.find<NearbyController>();
      
      // Directly query the NearbyController's active peers cache.
      // The controller naturally removes stale peers, executing the "2-sec rolling cache" logic for us natively.
      DiscoveredPeer? targetPeer;
      for (var peer in controller.users) {
        if (peer.rssi >= _rssiThreshold) {
          if (targetPeer == null || peer.rssi > targetPeer.rssi) {
            targetPeer = peer;
          }
        }
      }

      if (targetPeer != null) {
        // 1. Stop listening to prevent battery drain and false triggers
        _accelSubscription?.pause();
        
        // 2. Trigger Haptics
        HapticFeedback.heavyImpact();

        // 3. Update UI to Connecting State
        if (mounted) {
          setState(() {
            _currentState = ConnectState.connecting;
            _closestNodeId = targetPeer!.myHash;
          });
        }

        // 4. Execute the actual handshake routing through the existing controller
        await _executeMeshHandshake(_closestNodeId!);
      } else {
        // False alarm (bumped but no one is near). Reset debounce.
        await Future.delayed(const Duration(milliseconds: 500));
        _isProcessingBump = false;
      }
    } catch (e) {
      debugPrint('Error during kinetic bump: $e');
      _isProcessingBump = false;
    }
  }

  Future<void> _executeMeshHandshake(String targetNode) async {
    try {
      final controller = Get.find<NearbyController>();
      
      // Trigger actual BLE payload exchange
      controller.sendConnectionRequest(targetNode);
      
      // Network/Processing Delay simulation for visual effect
      await Future.delayed(const Duration(milliseconds: 1500));

      if (mounted) {
        setState(() {
          _currentState = ConnectState.success;
        });
      }
    } catch (e) {
      debugPrint('Handshake error: $e');
    }
  }

  @override
  void dispose() {
    // CRITICAL: Clean up sensors to prevent background battery drain
    _accelSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Deep background for the cinematic aesthetic
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildVisualizer(),
            const SizedBox(height: 40),
            _buildStatusText(),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizer() {
    // Minimalist UI that reacts to the state
    Color indicatorColor;
    double size;

    switch (_currentState) {
      case ConnectState.listening:
        indicatorColor = Colors.white24;
        size = 100;
        break;
      case ConnectState.connecting:
        indicatorColor = Colors.redAccent; // The "Red String" igniting
        size = 120;
        break;
      case ConnectState.success:
        indicatorColor = Colors.red; // Solid connection
        size = 150;
        break;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: indicatorColor, width: 3),
        boxShadow: _currentState != ConnectState.listening 
            ? [BoxShadow(color: indicatorColor.withValues(alpha: 0.5), blurRadius: 30, spreadRadius: 10)]
            : [],
      ),
      child: Center(
        child: Icon(
          _currentState == ConnectState.success ? Icons.all_inclusive : Icons.sensors,
          color: indicatorColor,
          size: size * 0.4,
        ),
      ),
    );
  }

  Widget _buildStatusText() {
    String text;
    switch (_currentState) {
      case ConnectState.listening:
        text = "Bump phones to connect";
        break;
      case ConnectState.connecting:
        text = "Binding strand...";
        break;
      case ConnectState.success:
        text = "Connection established.";
        break;
    }

    return Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 18,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
