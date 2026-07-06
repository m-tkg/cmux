# Personal-fork build commands (m-tkg/cmux). Not part of upstream cmux.

.PHONY: dist notary-setup clean-dist

# Build, sign (personal Developer ID), notarize (if the notarytool profile
# exists), and package a distributable cmux.app zip under dist/.
dist:
	./scripts/build-personal-release.sh

# One-time notarytool credential setup (requires an app-specific password
# from https://account.apple.com > Sign-In and Security > App-Specific Passwords).
notary-setup:
	@echo "Run:"
	@echo "  xcrun notarytool store-credentials cmux-personal \\"
	@echo "    --apple-id <your-apple-id> --team-id G72M73C546 --password <app-specific-password>"

clean-dist:
	rm -rf build-personal dist
