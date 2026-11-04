CORE := core
APP := app
LIB := $(CORE)/target/release/libremvel_core.a
# Must match deploymentTarget in app/project.yml.
export MACOSX_DEPLOYMENT_TARGET := 14.0

.PHONY: all core bindings app test run install-latest clean

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
		-derivedDataPath build CODE_SIGN_IDENTITY=- build -quiet

test:
	cd $(CORE) && cargo test

run: app
	open build/Build/Products/Release/Remvel.app

# The newest CI build of main, without building locally.
install-latest:
	scripts/install-latest.sh

clean:
	rm -rf build $(APP)/Remvel.xcodeproj
	cd $(CORE) && cargo clean
