import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The Credence mark: a sheet cut in two along an indented line, after the
/// medieval chirograph. This is the simplified small-size version, which reads
/// at 16 to 48 px.
class CredenceMark extends StatelessWidget {
  const CredenceMark({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Image.asset(
      'assets/brand/mark.png',
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
    ),
  );
}

/// Mark plus the serif wordmark.
class CredenceLogo extends StatelessWidget {
  const CredenceLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CredenceMark(size: size),
      SizedBox(width: size * 0.36),
      Text(
        'Credence',
        style: TextStyle(
          fontFamily: Fonts.serif,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.78,
          height: 1,
          color: C.ink,
          letterSpacing: 0.1,
        ),
      ),
    ],
  );
}
