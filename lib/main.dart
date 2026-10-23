import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/app_providers.dart';
import 'screens/caretaker_screen.dart';
import 'screens/patient_selection_screen.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(appRoleProvider);

    return MaterialApp(
      title: "Parkinson's Monitor",
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: role == AppRole.caretaker
          ? const CaretakerScreen()
          : const PatientSelectionScreen(),
    );
  }
}
