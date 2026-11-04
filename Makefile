CORE := core
APP := app
LIB := $(CORE)/target/release/libremvel_core.a
# CI passes its run number; 0 marks a local build, which never updates itself.
BUILD_NUMBER ?= 0
# Release builds pass the tag's version; otherwise project.yml's MARKETING_VERSION is used.
VERSION ?=
# Must match deploymentTarget in app/project.yml.
export MACOSX_DEPLOYMENT_TARGET := 14.0

.PHONY: all core bindings app test run install-latest install-nightly clean

all: app

core:
	cd $(CORE) && cargo build --release

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
		$(if $(VERSION),MARKETING_VERSION=$(VERSION)) build -quiet

test:
	cd $(CORE) && cargo test

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
