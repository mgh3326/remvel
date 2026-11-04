CORE := core
APP := app
# One library with both Apple Silicon and Intel code, so the app runs on either.
TARGETS := aarch64-apple-darwin x86_64-apple-darwin
LIB := $(CORE)/target/universal/libremvel_core.a
# CI passes its run number; 0 marks a local build, which never updates itself.
BUILD_NUMBER ?= 0
# Release builds pass the tag's version; otherwise project.yml's MARKETING_VERSION is used.
VERSION ?=
# Must match deploymentTarget in app/project.yml.
export MACOSX_DEPLOYMENT_TARGET := 14.0

.PHONY: all core bindings app test lint fmt check run install-latest install-nightly clean

all: app

core:
	cd $(CORE) && cargo build --release
	cd $(CORE) && for t in $(TARGETS); do cargo build --release --lib --target $$t || exit 1; done
	mkdir -p $(dir $(LIB))
	lipo -create $(foreach t,$(TARGETS),$(CORE)/target/$(t)/release/libremvel_core.a) -output $(LIB)

bindings: core
	cd $(CORE) && cargo run --release --bin uniffi-bindgen -- generate \
		--library target/release/libremvel_core.dylib --language swift --out-dir ../$(APP)/Generated
	mkdir -p $(APP)/Generated/include
	mv $(APP)/Generated/remvel_coreFFI.h $(APP)/Generated/include/
	mv $(APP)/Generated/remvel_coreFFI.modulemap $(APP)/Generated/include/module.modulemap

app: bindings
	cd $(APP) && xcodegen generate --quiet
	xcodebuild -project $(APP)/Remvel.xcodeproj -scheme Remvel -configuration Release \
		-derivedDataPath build CODE_SIGN_IDENTITY=- CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		$(if $(VERSION),MARKETING_VERSION=$(VERSION)) build -quiet

test:
	cd $(CORE) && cargo test

# Formatting and lints CI enforces. `make fmt` fixes formatting.
lint:
	cd $(CORE) && cargo fmt --check
	cd $(CORE) && cargo clippy --all-targets -- -D warnings

fmt:
	cd $(CORE) && cargo fmt

# What to run before pushing a core change.
check: lint test

run: app
	open build/Build/Products/Release/Remvel.app

# The latest release, without building locally. install-nightly: newest build of main.
install-latest:
	scripts/install-latest.sh

install-nightly:
	scripts/install-latest.sh --nightly

clean:
	rm -rf build $(APP)/Remvel.xcodeproj
	cd $(CORE) && cargo clean
