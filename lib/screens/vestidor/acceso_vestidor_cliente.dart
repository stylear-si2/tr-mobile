import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../auth/login_screen.dart';

class AccesoVestidorCliente extends StatelessWidget {
  const AccesoVestidorCliente({super.key});
  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Vestidor con IA')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 16),
            const Text(
              'El vestidor con IA está disponible solo para clientes con sesión iniciada.',
              textAlign: TextAlign.center,
            ),
            if (!auth.estaAutenticado) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
                ),
                child: const Text('Iniciar sesión'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
