.PHONY: build app install install-cli clean run help

CLI_INSTALL_DIR ?= $(HOME)/.local/bin

help: ## Show this help message
	@echo "VibeRouter - macOS Menu Bar App"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build the Swift executable (debug)
	@echo "🔨 Building Swift executable..."
	@cd src && swift build
	@echo "✅ Build complete: src/.build/debug/CLIProxyMenuBar"

release: ## Build the Swift executable (release)
	@echo "🔨 Building Swift executable (release)..."
	@./build.sh
	@echo "✅ Build complete: src/.build/release/CLIProxyMenuBar"

app: ## Create the .app bundle
	@echo "📦 Creating .app bundle..."
	@./create-app-bundle.sh
	@echo "✅ App bundle created: VibeRouter.app"

install: app ## Build and install to /Applications
	@echo "📲 Installing to /Applications..."
	@rm -rf "/Applications/VibeRouter.app"
	@rm -rf "/Applications/VibeProxy Ultra.app" "/Applications/VibeProxy.app"
	@cp -R "VibeRouter.app" /Applications/
	@xattr -cr "/Applications/VibeRouter.app" || true
	@mkdir -p "$(CLI_INSTALL_DIR)"
	@ln -sfn "/Applications/VibeRouter.app/Contents/MacOS/viberouter" "$(CLI_INSTALL_DIR)/viberouter"
	@echo "✅ Installed to /Applications/VibeRouter.app"
	@echo "✅ CLI installed to $(CLI_INSTALL_DIR)/viberouter"

install-cli: app ## Install the viberouter command to ~/.local/bin (override CLI_INSTALL_DIR)
	@mkdir -p "$(CLI_INSTALL_DIR)"
	@ln -sfn "$(CURDIR)/VibeRouter.app/Contents/MacOS/viberouter" "$(CLI_INSTALL_DIR)/viberouter"
	@echo "✅ CLI installed to $(CLI_INSTALL_DIR)/viberouter"

run: app ## Build and run the app
	@echo "🚀 Launching app..."
	@open "VibeRouter.app"

clean: ## Clean build artifacts
	@echo "🧹 Cleaning..."
	@rm -rf src/.build
	@rm -rf "VibeRouter.app"
	@rm -rf src/Sources/Resources/cli-proxy-api
	@rm -rf src/Sources/Resources/config.yaml
	@rm -rf src/Sources/Resources/static
	@echo "✅ Clean complete"

test: ## Run a quick test build
	@echo "🧪 Testing build..."
	@cd src && swift build
	@echo "✅ Test build successful"

info: ## Show project information
	@echo "Project: VibeRouter - macOS Menu Bar App"
	@echo "Language: Swift 5.9+"
	@echo "Platform: macOS 13.0+"
	@echo ""
	@echo "Files:"
	@find src/Sources -name "*.swift" -exec wc -l {} + | tail -1 | awk '{print "  Swift code: " $$1 " lines"}'
	@echo "  Documentation: 4 files"
	@echo ""
	@echo "Structure:"
	@tree -L 3 -I ".build" || echo "  (install 'tree' for better output)"

open: ## Open app bundle to inspect contents
	@if [ -d "VibeRouter.app" ]; then \
		open "VibeRouter.app"; \
	else \
		echo "❌ App bundle not found. Run 'make app' first."; \
	fi

edit-config: ## Edit the bundled config.yaml
	@if [ -d "VibeRouter.app" ]; then \
		open -e "VibeRouter.app/Contents/Resources/config.yaml"; \
	else \
		echo "❌ App bundle not found. Run 'make app' first."; \
	fi

# Shortcuts
all: app ## Same as 'app'
