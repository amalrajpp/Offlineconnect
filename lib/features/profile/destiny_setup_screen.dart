import 'package:flutter/material.dart';

class DestinySetupScreen extends StatefulWidget {
  const DestinySetupScreen({super.key});

  @override
  State<DestinySetupScreen> createState() => _DestinySetupScreenState();
}

class _DestinySetupScreenState extends State<DestinySetupScreen> {
  final List<String> _goals = [
    'Friendship',
    'Dating',
    'Networking',
    'Activity Partners',
  ];
  String _selectedGoal = 'Friendship';

  final List<String> _allInterests = [
    'Tech',
    'Art',
    'Music',
    'Fitness',
    'Travel',
    'Gaming',
    'Photography',
    'Reading',
    'Foodie',
    'Outdoors',
  ];
  final Set<String> _selectedInterests = {};

  double _introvertScale = 0.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          'Destiny Match ✨',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _buildSetupForm(theme),
    );
  }

  Widget _buildSetupForm(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.amber.shade300.withValues(alpha: 0.2),
                  Colors.orange.shade300.withValues(alpha: 0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.amber, size: 40),
                const SizedBox(height: 12),
                Text(
                  'Set your Deep Preferences',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'We will securely calculate your >90% compatible matches in the cloud and save their anonymous IDs to your device. When you walk past them without internet, your radar will glow gold!',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Goal Selection
          Text(
            'I am currently looking for:',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _goals.map((goal) {
              final isSelected = _selectedGoal == goal;
              return ChoiceChip(
                label: Text(goal),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) setState(() => _selectedGoal = goal);
                },
                selectedColor: theme.colorScheme.primary,
                labelStyle: TextStyle(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),

          // Interests Selection
          Text(
            'Select top interests (min 3):',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _allInterests.map((interest) {
              final isSelected = _selectedInterests.contains(interest);
              return FilterChip(
                label: Text(interest),
                selected: isSelected,
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _selectedInterests.add(interest);
                    } else {
                      _selectedInterests.remove(interest);
                    }
                  });
                },
                selectedColor: Colors.amber.shade200,
                checkmarkColor: Colors.amber.shade900,
                labelStyle: TextStyle(
                  color: isSelected
                      ? Colors.amber.shade900
                      : theme.colorScheme.onSurface,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),

          // Vibe Slider
          Text(
            'Social Energy:',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Introverted', style: theme.textTheme.labelMedium),
              Text('Extraverted', style: theme.textTheme.labelMedium),
            ],
          ),
          Slider(
            value: _introvertScale,
            activeColor: theme.colorScheme.primary,
            inactiveColor: theme.colorScheme.surfaceContainerHigh,
            onChanged: (val) => setState(() => _introvertScale = val),
          ),
          const SizedBox(height: 48),

          // Sync Button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: null, // Destiny matching is coming soon.
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                disabledBackgroundColor:
                    theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              icon: Icon(
                Icons.cloud_sync,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
              label: Text(
                'Coming Soon',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Destiny Match is under development. Stay tuned!',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
