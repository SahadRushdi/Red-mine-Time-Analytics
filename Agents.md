# AI Agent Onboarding & Coding Standards

This document serves as the foundational guide for AI agents and developers working on the `redmine_time_analytics` plugin. It outlines the project's architectural principles, technology stack, and engineering standards.

## 🚀 Technology Stack

The plugin follows a modern "Tailwind-first" approach within the Redmine ecosystem:

- **Core Framework**: Redmine (Ruby on Rails)
- **Styling**: Tailwind CSS v3 (Utility-first CSS) ***[imported using npm package]***
- **UI Components**: Flowbite (Modern UI library)  ***[imported using npm package]***
- **Data Visualization**: Chart.js (Interactive dashboards) ***[uses CDN link]***
- **Icons**: Material Icons / Flowbite SVG Icons ***[uses CDN link]***
- **Fonts**: Inter (Modern sans-serif)

---

## 🏗️ Architectural Principles

### 1. The "Surgical Update" Rule
When modifying views (ERB files), always prioritize surgical updates over complete rewrites unless a component is being fully modernized. Ensure that existing Redmine logic (like localization helpers `l(:label_name)`) is preserved.

### 2. DRY (Don't Repeat Yourself)
- **Helpers**: Consolidate repetitive logic into `app/helpers/time_analytics_helper.rb`.
- **Partials**: Break down large views into reusable partials (e.g., `_includes.html.erb`).
- **CSS**: Avoid writing custom CSS in `time_analytics.css`. Use Tailwind utility classes directly in the ERB templates.

### 3. Modernization Standards
All modernized components must adhere to the following:
- **Primary Color**: Always use `#3b82f6` (Tailwind `blue-500` equivalent) for primary actions.
- **Hover States**: Selected buttons should use a darker blue (`#2563eb`). Unselected buttons must maintain black text (`!text-gray-700` to `hover:!text-gray-900`) to avoid visibility issues.
- **Theme Overrides**: Use Tailwind's `!` (important) modifier sparingly but effectively to ensure Redmine themes (like Purplemine2) do not override modernized dashboard styles.

---

## 🛠️ Coding Standards for AI Agents

### Naming Conventions
- **Ruby/Rails**: Follow standard Rails conventions (snake_case for methods/variables, PascalCase for classes).
- **JavaScript**: Use camelCase for variables and functions.
- **CSS Classes**: Use standard Tailwind utility names. For custom IDs, use kebab-case (e.g., `time-analytics-form`).

### JavaScript Best Practices
- **Event Listeners**: Always use `DOMContentLoaded` for initializations.
- **Conflicts**: Check for redundant functions. For example, do not define `toggleCustomDateRange` in multiple files.
- **Interactivity**: Prefer native browser behavior (like `onchange: 'this.form.submit()'`) for simple filters to keep the codebase lightweight.

### CSS & Tailwind
- **Inline Styles**: Only use explicit `style` attributes as a "fail-safe" fallback for critical brand colors (e.g., `#3b82f6` on selected buttons).
- **Responsive Design**: Always use Tailwind's responsive prefixes (`md:`, `lg:`) to ensure dashboard cards stack correctly on mobile.

---

## 📝 Verification Checklist for Agents

Before concluding any task, verify the following:
1. [ ] **Localization**: Are all strings wrapped in `l()` helpers?
2. [ ] **Visibility**: Check hover states in both selected and unselected modes. Is the text readable?
3. [ ] **Consistency**: Does the primary blue color match `#3b82f6` exactly?
4. [ ] **Cleanup**: Have you removed unused dependencies or redundant JavaScript?
5. [ ] **Documentation**: Have you updated `MODERNIZATION_IMPLEMENTATION_PLAN.md` or the relevant completion reports?

---

## 🚦 Phase Tracking
We are currently in **Phase 3: Component-by-Component Migration**. Refer to `MODERNIZATION_IMPLEMENTATION_PLAN.md` for the current roadmap and `PHASE3.1_MODERNIZATION_COMPLETE.md` for recent header/filter updates.
