# Deployment Guide - Production Ready Plugin

## ✅ Zero Node.js Deployment

Your plugin is now **production-ready** with all compiled assets committed to git. Deployment requires **NO Node.js** on the server!

---

## 🚀 Quick Start (Production Deployment)

### For Sysadmins/Deployers

```bash
# 1. Clone plugin to Redmine
cd /path/to/redmine/plugins
git clone <your-repo-url> redmine_time_analytics

# 2. Start Redmine (that's it!)
cd /path/to/redmine
bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

**No npm install, no Node.js, no build steps!** ✨

---

## 📦 What's Included (Committed to Git)

### Compiled Assets (Production-Ready)
All these files are **committed** and ready to use:

```
assets/stylesheets/
├── tailwind.output.css    # 49KB - Compiled Tailwind CSS
├── flowbite.min.css       # 187KB - Flowbite styles
└── time_analytics.css     # Legacy CSS (temporary)

assets/javascripts/
├── flowbite.min.js        # 132KB - Flowbite components
├── time_analytics_charts.js
└── time_analytics.js
```

### Configuration Files (Committed)
```
package.json               # Build scripts (for devs only)
package-lock.json          # Dependency locking
tailwind.config.js         # Tailwind configuration
postcss.config.js          # PostCSS configuration
```

### NOT Committed
```
node_modules/              # 320MB - Regenerate with npm install
```

---

## 🔄 Running the Plugin

### Option 1: Fresh Installation

```bash
cd /path/to/redmine

# Run migration (if first time)
RAILS_ENV=production bundle exec rake redmine:plugins:migrate NAME=redmine_time_analytics

# Start Redmine
bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

### Option 2: Update Existing Installation

```bash
cd /path/to/redmine/plugins/redmine_time_analytics

# Pull latest changes
git pull

# Restart Redmine
cd /path/to/redmine
bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

---

## 👨‍💻 Development Workflow

### For Developers Making Changes

**Prerequisites**: Node.js and npm installed

```bash
# 1. Clone repository
git clone <repo-url>
cd redmine/plugins/redmine_time_analytics

# 2. Install dev dependencies
npm install

# 3. Start development mode
npm run watch
```

**In another terminal**:
```bash
cd /path/to/redmine
bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

**Make changes**:
1. Edit `.html.erb` files (add Tailwind classes)
2. Save file → Tailwind auto-rebuilds CSS (~1 second)
3. Refresh browser → See changes

**Before committing**:
```bash
# Build production CSS
npm run build

# Commit EVERYTHING including compiled assets
git add assets/stylesheets/tailwind.output.css
git add assets/stylesheets/flowbite.min.css
git add assets/javascripts/flowbite.min.js
git add <your-changed-files>
git commit -m "Modernize: add Tailwind styling"
git push
```

---

## 📋 Asset Loading Strategy

### Local Assets (No CDN Dependency)
✅ **Tailwind CSS** - Local file, version-controlled  
✅ **Flowbite CSS** - Local file, version-controlled  
✅ **Flowbite JS** - Local file, version-controlled  

**Benefits**:
- Works offline
- No CDN downtime risk
- Version-locked
- Faster loading (local)

### CDN Assets (Font Only)
✅ **Inter Font** - Google Fonts CDN  
✅ **Material Icons** - Google Fonts CDN  
✅ **Chart.js** - jsDelivr CDN (already in use)

**Rationale**: Fonts are universally cached, small size, high availability

---

## 🧪 Verification After Deployment

### 1. Check Files Exist
```bash
cd /path/to/redmine/plugins/redmine_time_analytics

# Check compiled assets
ls -lh assets/stylesheets/tailwind.output.css   # Should be ~49KB
ls -lh assets/stylesheets/flowbite.min.css      # Should be ~187KB
ls -lh assets/javascripts/flowbite.min.js       # Should be ~132KB
```

### 2. Start Redmine
```bash
cd /path/to/redmine
bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

### 3. Access Plugin
- Open browser: `http://your-server:3000`
- Login to Redmine
- Click "Time Analytics" in top menu
- Dashboard should load with modern styling

### 4. Verify Assets Loaded (Browser DevTools)

**Open DevTools (F12) → Network Tab**:
- ✅ `/plugin_assets/redmine_time_analytics/stylesheets/tailwind.output.css` (49KB)
- ✅ `/plugin_assets/redmine_time_analytics/stylesheets/flowbite.min.css` (187KB)
- ✅ `/plugin_assets/redmine_time_analytics/javascripts/flowbite.min.js` (132KB)

**Console Tab**:
- ❌ No errors related to missing files

---

## 🐛 Troubleshooting

### Issue: CSS Not Loading

**Symptom**: Page looks broken or styles missing

**Solution 1**: Verify files exist
```bash
cd /path/to/redmine/plugins/redmine_time_analytics
ls -lh assets/stylesheets/tailwind.output.css
ls -lh assets/stylesheets/flowbite.min.css
```

**Solution 2**: Clear Rails asset cache
```bash
cd /path/to/redmine
RAILS_ENV=production bundle exec rake tmp:cache:clear
RAILS_ENV=production bundle exec rake assets:clean
```
Then restart Redmine.

**Solution 3**: Check file permissions
```bash
cd /path/to/redmine/plugins/redmine_time_analytics
chmod 644 assets/stylesheets/*.css
chmod 644 assets/javascripts/*.js
```

---

### Issue: Flowbite Components Not Working

**Symptom**: Dropdowns, modals don't work

**Solution**: Verify Flowbite JS is loaded
```bash
# Check file exists
ls -lh assets/javascripts/flowbite.min.js

# Should be ~132KB
```

Check browser console (F12) for JavaScript errors.

---

### Issue: Missing Compiled Assets (Developer)

**Symptom**: After pulling latest code, CSS changes not reflected

**Solution**: Rebuild Tailwind CSS
```bash
cd /path/to/redmine/plugins/redmine_time_analytics

# Install dependencies (if first time)
npm install

# Build CSS
npm run build

# Commit the output
git add assets/stylesheets/tailwind.output.css
git commit -m "Rebuild: update Tailwind CSS"
```

---

## 📊 File Size Reference

| File | Size | Type |
|------|------|------|
| `tailwind.output.css` | 49KB | Compiled CSS |
| `flowbite.min.css` | 187KB | Flowbite styles |
| `flowbite.min.js` | 132KB | Flowbite JS |
| `package-lock.json` | 64KB | Dependency lock |
| **Total committed assets** | **368KB** | Production-ready |
| `node_modules/` (ignored) | 320MB | Dev only |

---

## 🎯 Deployment Checklist

### Before Pushing to Git (Developers)

- [ ] Ran `npm run build` to compile CSS
- [ ] Verified `tailwind.output.css` size (~49KB)
- [ ] Verified `flowbite.min.css` exists (~187KB)
- [ ] Verified `flowbite.min.js` exists (~132KB)
- [ ] Committed all compiled assets
- [ ] Committed `package-lock.json`
- [ ] Tested locally in Redmine

### Before Deploying to Production (Sysadmins)

- [ ] Pulled latest code: `git pull`
- [ ] Verified compiled assets exist
- [ ] Restarted Redmine
- [ ] Checked browser console for errors
- [ ] Verified plugin loads correctly
- [ ] Tested basic functionality

---

## 💡 Key Differences from Typical Frontend Apps

### Why Commit Compiled Assets?

**Typical web app**: Compiled assets in `.gitignore`, built during CI/CD

**Redmine plugin**: Compiled assets committed to git

**Reasons**:
1. ✅ **Simple deployment** - No build step on server
2. ✅ **No Node.js** - Production servers don't need Node.js
3. ✅ **Version control** - CSS changes tracked in git
4. ✅ **Rollback friendly** - Git checkout = instant rollback
5. ✅ **Manual installation** - Plugins installed by git clone, not npm

---

## 🔄 Update Workflow

### Developer Updates Code

```bash
# 1. Make changes to ERB files
vim app/views/time_analytics/individual_dashboard.html.erb

# 2. Rebuild CSS
npm run build

# 3. Commit everything
git add -A
git commit -m "Update: modernize metric cards"
git push
```

### Sysadmin Deploys Update

```bash
# 1. Pull changes
cd /path/to/redmine/plugins/redmine_time_analytics
git pull

# 2. Restart Redmine
cd /path/to/redmine
# Press Ctrl+C to stop
bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

**That's it!** No npm install, no build steps needed.

---

## 📞 Support

### For Deployment Issues
1. Check files exist: `ls -lh assets/stylesheets/`
2. Check permissions: `chmod 644 assets/stylesheets/*.css`
3. Clear cache: `rake tmp:cache:clear`
4. Check Redmine logs: `log/production.log`

### For Development Issues
1. Run `npm install` to get dependencies
2. Run `npm run build` to rebuild CSS
3. Check for compile errors in terminal
4. Commit compiled output before pushing

---

## ✅ Summary

Your plugin is now **production-ready** with:

- ✅ All assets compiled and committed to git
- ✅ Zero Node.js dependency on production servers
- ✅ Simple deployment: git clone + restart Redmine
- ✅ Version-controlled CSS (trackable changes)
- ✅ Offline-capable (no CDN for core assets)
- ✅ Fast loading (local assets)

**Deployment is as simple as**:
```bash
git clone <repo> && cd /path/to/redmine && bundle exec rails server
```

No Node.js, no npm, no build steps! 🚀
