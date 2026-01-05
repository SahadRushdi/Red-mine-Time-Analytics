#!/bin/bash

# Installation Script for Sri Lankan Working Days Feature
# Redmine Time Analytics Plugin
# 
# This script installs the required gems and restarts Redmine

set -e  # Exit on error

echo "=========================================="
echo "Sri Lankan Working Days - Installation"
echo "=========================================="
echo ""

# Define Redmine root directory
REDMINE_ROOT="/home/sahad-rushdi/redmine"
PLUGIN_DIR="$REDMINE_ROOT/plugins/redmine_time_analytics"

echo "Step 1: Checking Redmine installation..."
if [ ! -d "$REDMINE_ROOT" ]; then
    echo "❌ Error: Redmine directory not found at $REDMINE_ROOT"
    exit 1
fi

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "❌ Error: Plugin directory not found at $PLUGIN_DIR"
    exit 1
fi

echo "✅ Redmine found at: $REDMINE_ROOT"
echo "✅ Plugin found at: $PLUGIN_DIR"
echo ""

echo "Step 2: Checking plugin files..."
if [ ! -f "$PLUGIN_DIR/Gemfile" ]; then
    echo "❌ Error: Plugin Gemfile not found"
    exit 1
fi

if [ ! -f "$PLUGIN_DIR/config/initializers/business_time.rb" ]; then
    echo "❌ Error: Business time initializer not found"
    exit 1
fi

if [ ! -f "$PLUGIN_DIR/app/controllers/time_analytics_controller.rb" ]; then
    echo "❌ Error: Controller file not found"
    exit 1
fi

echo "✅ All required files present"
echo ""

echo "Step 3: Installing gems..."
cd "$REDMINE_ROOT"

echo "Running: bundle install"
bundle install

if [ $? -ne 0 ]; then
    echo "❌ Error: Bundle install failed"
    exit 1
fi

echo "✅ Gems installed successfully"
echo ""

echo "Step 4: Verifying gem installation..."
echo "Checking for business_time..."
bundle list | grep business_time

echo "Checking for holidays..."
bundle list | grep holidays

echo ""
echo "✅ Gems verified"
echo ""

echo "Step 5: Checking Redmine process..."
# Check if Redmine is running
if pgrep -f "rails.*server" > /dev/null; then
    echo "⚠️  Redmine server is running"
    echo ""
    echo "Please restart Redmine manually:"
    echo ""
    echo "Option 1 - WEBrick (development):"
    echo "  1. Press Ctrl+C to stop the server"
    echo "  2. Run: cd $REDMINE_ROOT && bundle exec rails server -e production"
    echo ""
    echo "Option 2 - Passenger:"
    echo "  Run: touch $REDMINE_ROOT/tmp/restart.txt"
    echo ""
    echo "Option 3 - Systemd service:"
    echo "  Run: sudo systemctl restart redmine"
    echo ""
elif systemctl is-active --quiet redmine 2>/dev/null; then
    echo "⚠️  Redmine service detected"
    echo ""
    read -p "Do you want to restart the Redmine service? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Restarting Redmine service..."
        sudo systemctl restart redmine
        echo "✅ Redmine service restarted"
    else
        echo "⚠️  Please restart Redmine service manually:"
        echo "  Run: sudo systemctl restart redmine"
    fi
elif [ -f "$REDMINE_ROOT/tmp/pids/server.pid" ]; then
    echo "⚠️  Redmine PID file found, but process may not be running"
    echo "Please restart Redmine manually"
else
    echo "ℹ️  No running Redmine process detected"
    echo "Please start Redmine:"
    echo "  cd $REDMINE_ROOT && bundle exec rails server -e production"
fi

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "📋 Next Steps:"
echo "1. Ensure Redmine is restarted (see above)"
echo "2. Navigate to: Time Analytics → Individual Dashboard"
echo "3. Log some time entries across a week"
echo "4. Verify that weekends are excluded from average calculation"
echo ""
echo "📚 Documentation:"
echo "- Quick Start: $PLUGIN_DIR/QUICK_START.md"
echo "- Full Guide: $PLUGIN_DIR/WORKING_DAYS_IMPLEMENTATION.md"
echo "- Code Changes: $PLUGIN_DIR/CODE_CHANGES.md"
echo ""
echo "🧪 Test the implementation:"
echo "  cd $REDMINE_ROOT"
echo "  bundle exec rails console production"
echo "  > require 'business_time'"
echo "  > Date.new(2024, 1, 6).workday?  # Saturday -> false"
echo "  > Date.new(2024, 1, 8).workday?  # Monday -> true"
echo ""
echo "✅ Sri Lankan working days feature is now active!"
echo ""
