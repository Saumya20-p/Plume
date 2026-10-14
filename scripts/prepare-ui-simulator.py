#!/usr/bin/env python3
"""Apply upstream MLX #354 to a disposable Xcode dependency checkout.

The locked 0.30.2 release has a simulator linker defect. This does not change
Package.resolved or device production sources. MLX synthesis still requires a
physical device. See https://github.com/ml-explore/mlx-swift/pull/354.
"""
import pathlib
import sys
root = pathlib.Path(sys.argv[1]) / 'SourcePackages/checkouts/mlx-swift/Source/Cmlx/metal-cpp/Metal'
for name, symbol in [('MTLTensor.hpp', 'TensorDomain'), ('MTLIOCommandQueue.hpp', 'IOErrorDomain')]:
    path = root / name
    old = f'_MTL_PRIVATE_DEF_CONST(NS::ErrorDomain, {symbol});'
    new = f'_MTL_PRIVATE_DEF_WEAK_CONST(NS::ErrorDomain, {symbol});'
    text = path.read_text()
    if old not in text and new not in text:
        raise SystemExit(f'Unexpected upstream header: {path}')
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(text.replace(old, new))
print('Applied upstream MLX simulator link fix to disposable checkout.')
