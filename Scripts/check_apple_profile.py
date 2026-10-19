"""Read capability status only; never print provisioning data or signing secrets."""
import base64
import os
import plistlib
import subprocess

encoded = os.environ.get("BUILD_PROVISION_PROFILE_BASE64", "")
if not encoded:
    print("::warning::Apple sign-in distribution capability not checked: no provisioning profile is available to this run.")
    raise SystemExit(0)
try:
    decoded = base64.b64decode(encoded, validate=True)
    result = subprocess.run(["security", "cms", "-D"], input=decoded, capture_output=True, check=True)
    profile = plistlib.loads(result.stdout)
except Exception:
    print("::warning::Could not inspect the distribution profile for Apple sign-in capability.")
    raise SystemExit(0)
enabled = "Default" in profile.get("Entitlements", {}).get("com.apple.developer.applesignin", [])
if enabled:
    print("Distribution profile includes Sign in with Apple.")
else:
    print("::warning::Distribution profile is missing Sign in with Apple. Enable the App ID capability, regenerate the App Store Connect distribution profile, and replace BUILD_PROVISION_PROFILE_BASE64 before release.")
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as output:
        output.write("\nSign in with Apple distribution profile: " + ("capability present." if enabled else "capability missing; update provisioning before release.") + "\n")
