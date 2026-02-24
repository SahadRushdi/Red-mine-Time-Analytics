#!/bin/bash

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         PRODUCTION-READY VERIFICATION SCRIPT                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

ERRORS=0

echo "Checking required files..."
echo ""

# Check compiled assets
if [ -f "assets/stylesheets/tailwind.output.css" ]; then
    SIZE=$(stat -f%z "assets/stylesheets/tailwind.output.css" 2>/dev/null || stat -c%s "assets/stylesheets/tailwind.output.css" 2>/dev/null)
    SIZE_KB=$((SIZE / 1024))
    echo "✓ tailwind.output.css exists (${SIZE_KB}KB)"
else
    echo "✗ tailwind.output.css MISSING"
    ERRORS=$((ERRORS + 1))
fi

if [ -f "assets/stylesheets/flowbite.min.css" ]; then
    SIZE=$(stat -f%z "assets/stylesheets/flowbite.min.css" 2>/dev/null || stat -c%s "assets/stylesheets/flowbite.min.css" 2>/dev/null)
    SIZE_KB=$((SIZE / 1024))
    echo "✓ flowbite.min.css exists (${SIZE_KB}KB)"
else
    echo "✗ flowbite.min.css MISSING"
    ERRORS=$((ERRORS + 1))
fi

if [ -f "assets/javascripts/flowbite.min.js" ]; then
    SIZE=$(stat -f%z "assets/javascripts/flowbite.min.js" 2>/dev/null || stat -c%s "assets/javascripts/flowbite.min.js" 2>/dev/null)
    SIZE_KB=$((SIZE / 1024))
    echo "✓ flowbite.min.js exists (${SIZE_KB}KB)"
else
    echo "✗ flowbite.min.js MISSING"
    ERRORS=$((ERRORS + 1))
fi

if [ -f "package-lock.json" ]; then
    echo "✓ package-lock.json exists"
else
    echo "✗ package-lock.json MISSING"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "Checking .gitignore configuration..."
echo ""

if [ -f ".gitignore" ]; then
    # Check actual ignore rules (excluding comments)
    if ! grep -v "^#" .gitignore | grep -q "tailwind.output.css"; then
        echo "✓ tailwind.output.css NOT ignored (will be committed)"
    else
        echo "✗ tailwind.output.css is ignored (should be committed)"
        ERRORS=$((ERRORS + 1))
    fi
    
    if ! grep -v "^#" .gitignore | grep -q "package-lock.json"; then
        echo "✓ package-lock.json NOT ignored (will be committed)"
    else
        echo "✗ package-lock.json is ignored (should be committed)"
        ERRORS=$((ERRORS + 1))
    fi
    
    if grep -v "^#" .gitignore | grep -q "node_modules/"; then
        echo "✓ node_modules/ IS ignored (correct)"
    else
        echo "✗ node_modules/ NOT ignored (should be ignored)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "✗ .gitignore MISSING"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "Checking view files..."
echo ""

if [ -f "app/views/time_analytics/_includes.html.erb" ]; then
    if grep -q "flowbite.min.css.*plugin.*redmine_time_analytics" app/views/time_analytics/_includes.html.erb; then
        echo "✓ _includes.html.erb uses local Flowbite CSS"
    else
        echo "✗ _includes.html.erb NOT using local Flowbite CSS"
        ERRORS=$((ERRORS + 1))
    fi
    
    if grep -q "flowbite.min.js.*plugin.*redmine_time_analytics" app/views/time_analytics/_includes.html.erb; then
        echo "✓ _includes.html.erb uses local Flowbite JS"
    else
        echo "✗ _includes.html.erb NOT using local Flowbite JS"
        ERRORS=$((ERRORS + 1))
    fi
    
    # Check NO CDN links
    if ! grep -q "cdn.jsdelivr.net/npm/flowbite" app/views/time_analytics/_includes.html.erb; then
        echo "✓ No Flowbite CDN links found (correct)"
    else
        echo "✗ Still using Flowbite CDN (should use local)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "✗ _includes.html.erb MISSING"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ ALL CHECKS PASSED!"
    echo ""
    echo "Your plugin is PRODUCTION-READY!"
    echo ""
    echo "Summary:"
    echo "  • Compiled assets: Ready to commit"
    echo "  • Flowbite: Local files (no CDN)"
    echo "  • Deployment: No Node.js needed"
    echo ""
    echo "Next step: Commit and push to git"
    exit 0
else
    echo "❌ $ERRORS ERROR(S) FOUND!"
    echo ""
    echo "Please fix the issues above before deployment."
    exit 1
fi
