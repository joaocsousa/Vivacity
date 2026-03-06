## Vivacity Privileged Helper

This target contains the privileged XPC helper process used for raw block-device reads.

Mach service name:
- `com.joao.Vivacity.PrivilegedHelper`

Important:
- Debug builds place the app bundle at `build/Debug/Vivacity.app`.
- The embedded helper binary is copied to `build/Debug/Vivacity.app/Contents/Library/LaunchServices/com.joao.Vivacity.PrivilegedHelper`.
- Installing the helper with `SMJobBless` requires proper code signing requirements to match between app and helper.
- If helper install is unavailable, the app falls back to existing privileged read strategies.
