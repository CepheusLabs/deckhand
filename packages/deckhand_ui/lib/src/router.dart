import 'package:go_router/go_router.dart';

import 'screens/welcome_screen.dart';
import 'screens/pick_printer_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/verify_screen.dart';
import 'screens/choose_path_screen.dart';
import 'screens/firmware_screen.dart';
import 'screens/webui_screen.dart';
import 'screens/kiauh_screen.dart';
import 'screens/screen_choice_screen.dart';
import 'screens/services_screen.dart';
import 'screens/files_screen.dart';
import 'screens/hardening_screen.dart';
import 'screens/flash_target_screen.dart';
import 'screens/choose_os_screen.dart';
import 'screens/flash_confirm_screen.dart';
import 'screens/flash_progress_screen.dart';
import 'screens/first_boot_screen.dart';
import 'screens/first_boot_setup_screen.dart';
import 'screens/review_screen.dart';
import 'screens/progress_screen.dart';
import 'screens/done_screen.dart';
import 'screens/settings_screen.dart';

GoRouter buildDeckhandRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const WelcomeScreen()),
        GoRoute(path: '/pick-printer', builder: (_, __) => const PickPrinterScreen()),
        GoRoute(path: '/connect', builder: (_, __) => const ConnectScreen()),
        GoRoute(path: '/verify', builder: (_, __) => const VerifyScreen()),
        GoRoute(path: '/choose-path', builder: (_, __) => const ChoosePathScreen()),

        // Flow A (stock keep)
        GoRoute(path: '/firmware', builder: (_, __) => const FirmwareScreen()),
        GoRoute(path: '/webui', builder: (_, __) => const WebuiScreen()),
        GoRoute(path: '/kiauh', builder: (_, __) => const KiauhScreen()),
        GoRoute(path: '/screen-choice', builder: (_, __) => const ScreenChoiceScreen()),
        GoRoute(path: '/services', builder: (_, __) => const ServicesScreen()),
        GoRoute(path: '/files', builder: (_, __) => const FilesScreen()),
        GoRoute(path: '/hardening', builder: (_, __) => const HardeningScreen()),

        // Flow B (fresh flash)
        GoRoute(path: '/flash-target', builder: (_, __) => const FlashTargetScreen()),
        GoRoute(path: '/choose-os', builder: (_, __) => const ChooseOsScreen()),
        GoRoute(path: '/flash-confirm', builder: (_, __) => const FlashConfirmScreen()),
        GoRoute(path: '/flash-progress', builder: (_, __) => const FlashProgressScreen()),
        GoRoute(path: '/first-boot', builder: (_, __) => const FirstBootScreen()),
        GoRoute(path: '/first-boot-setup', builder: (_, __) => const FirstBootSetupScreen()),

        // Shared tail
        GoRoute(path: '/review', builder: (_, __) => const ReviewScreen()),
        GoRoute(path: '/progress', builder: (_, __) => const ProgressScreen()),
        GoRoute(path: '/done', builder: (_, __) => const DoneScreen()),
        GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      ],
    );
