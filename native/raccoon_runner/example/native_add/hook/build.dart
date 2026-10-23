import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds src/native_add.c into the library lib/native_add.dart binds to,
/// with the header from native_add_defs, a path dependency.
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    await CBuilder.library(
      name: 'native_add',
      assetName: 'native_add.dart',
      sources: const ['src/native_add.c'],
      includes: const ['../native_add_defs/include'],
    ).run(input: input, output: output);
  });
}
