# Redmine Time Analytics Plugin

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Redmine Compatibility](https://img.shields.io/badge/Redmine-5.0.x+-green.svg)](https://www.redmine.org/)

## Overview

Redmine Time Analytics is a comprehensive time tracking analytics and reporting plugin for Redmine that provides detailed insights into time logging patterns, productivity metrics, and project time distribution. The plugin features an optimized side-by-side layout, interactive charts, detailed reports, and export capabilities to help users and managers track time effectively with maximum information density.

## Features

### Individual Dashboard
- **Personal Time Analytics**: View your own logged time with comprehensive filtering
- **Multiple View Modes**: Switch between Time Entries, Activity Analysis, and Project views
- **Multiple Time Periods**: Today, this week, last week, this month, this year, or custom date ranges
- **Flexible Grouping**: Group data by daily, weekly, monthly, or yearly periods
- **Interactive Charts**: Bar, line, and pie charts powered by Chart.js with real-time switching
- **Modern Chart Controls**: Custom-styled dropdown with hover/focus states and matching button sizes
- **View-Specific Default Charts**: Automatic chart type selection based on view mode (Bar for Time Entries, Pie for Activity/Project)
- **Optimized Layout**: Side-by-side summary and visualization for maximum screen utilization
- **Compact Statistics**: 2x2 grid layout showing total hours, entry counts, daily averages, max/min daily hours
- **Activity & Project Analysis**: Cross-tabulation matrix showing distribution across time periods
  - **Dual View System**: Toggle between detailed pivot table and summary view for all groupings
  - **Context-Aware Charts**: Pie charts show activities/projects in summary view, time periods in detailed view
  - **Horizontal Distribution Bars**: Visual percentage bars in summary tables showing proportional time distribution
- **Advanced Search**: Search across projects, issues, and comments
- **Export Functionality**: Export data and visualizations as CSV
- **Responsive Design**: Works on desktop and mobile devices with adaptive layouts
- **Percentage Display**: Pie charts show percentages and hours for each segment (e.g., "Development (68.9%, 31.1h)")

### UI/UX Improvements
- **Modern Button System**: Unified button styling with shared base classes for consistency
  - Primary blue buttons for main actions (Apply, Show Summary View, Active toggle)
  - Secondary gray buttons for alternate actions (Clear, Hide Chart)
  - Consistent sizing and alignment across all controls
- **Space-Optimized Layout**: Summary section (280px) + Visualization section (remaining space)
- **Enhanced Summary Tables**: Horizontal distribution bars with percentages (40% column width)
  - Time Entries grouped view (Weekly/Monthly/Yearly)
  - Activity summary view
  - Project summary view
- **Information Density**: All key metrics visible without scrolling
- **Consistent Date Formatting**: Unified date format across all views (e.g., "Dec 29, 2025")
- **Collapsible Filters**: Toggle filter visibility to maximize content area with aligned action buttons
- **Modern Form Controls**: Styled dropdowns with custom arrows and hover effects
- **Mobile-First Design**: Sections stack vertically on smaller screens
- **Smart Chart Switching**: Charts automatically update when toggling between summary and detailed views

### Coming Soon
- **Team Dashboard**: Team productivity insights and workload distribution
- **Custom Dashboard**: Personalized analytics views with configurable widgets

## Installation

1. Clone the repository into your Redmine plugins directory:
   ```bash
   cd path/to/redmine/plugins
   git clone https://github.com/your-repo/redmine_time_analytics.git
   ```

2. Install dependencies (if any):
   ```bash
   bundle install
   ```

3. Run migrations (if any):
   ```bash
   bundle exec rake redmine:plugins:migrate RAILS_ENV=production
   ```

4. Restart your Redmine instance.

## Usage

### Getting Started
1. After installation, you'll see "Time Analytics" in the top menu
2. Click on "Time Analytics" to access the Individual Dashboard
3. Use the toggle buttons to switch between view modes:
   - **Time Entries**: Detailed list of individual time entries
   - **Activity**: Analysis grouped by activity types with cross-tabulation for weekly/monthly/yearly views
   - **Grouping**: Time data grouped by selected time period

### Dashboard Features
4. **Filter Controls**: Click the filter icon to show/hide advanced filters
   - Select time period (today, this week, last week, this month, this year, or custom range)
   - Choose grouping (daily, weekly, monthly, yearly)
   - Search for specific projects, issues, or comments
5. **Analytics Section**: View summary statistics and interactive charts side-by-side
   - **Summary**: Compact 2x2 grid showing key metrics
   - **Visualization**: Interactive charts with view-specific defaults and real-time type switching (bar, line, pie)
6. **Activity Analysis Views**:
   - **Detailed View**: Shows pivot table with activity distribution across time periods
   - **Summary View**: Shows simple activity list with total hours per activity
   - **Toggle Button**: Switch between views using "Show Summary View" / "Show Detailed View" button
7. **Data Table**: Detailed results below the analytics section with pagination
8. **Export**: Export filtered data and visualizations as CSV for further analysis

### Chart Interaction
- **View-Specific Defaults**: Time Entries use bar charts, Activity and Grouping views use pie charts by default
- Use the chart type dropdown to switch between bar, line, and pie charts
- Toggle chart visibility using the "Show/Hide Chart" button
- **Context-Aware Pie Charts**: 
  - In Activity view detailed mode: Shows time periods (dates, weeks, months, years)
  - In Activity view summary mode: Shows activities with percentages
- **Enhanced Pie Chart Labels**: Display percentages and hours (e.g., "Development (68.9%, 31.1h)")
- All charts are responsive and work across different screen sizes

## Technical Details

### Architecture
- **Controllers**: `TimeAnalyticsController` handles all dashboard requests with multi-view support
- **Helpers**: `TimeAnalyticsHelper` provides view helper methods and consistent date formatting
- **Views**: Optimized ERB templates with side-by-side analytics layout
- **Chart Library**: Chart.js for interactive visualizations with real-time type switching
- **Utilities**: Modular chart generation and CSV export helpers

### UI/UX Design
The plugin implements a modern, space-optimized design:
- **Analytics Section**: Flexbox layout with summary (280px fixed) + visualization (flex-grow)
- **Responsive Breakpoints**: Desktop side-by-side, mobile stacked layout
- **Information Hierarchy**: Analytics first, detailed data second
- **Consistent Formatting**: Unified Monday-Sunday week display across all views
- **Modern Button System**: Shared base classes (button-base, button-primary, button-secondary) for consistent styling
- **Visual Data Representation**: Horizontal distribution bars in summary tables with 40% column width
- **Professional Controls**: Custom-styled form elements with hover/focus states

### Chart Integration
Advanced Chart.js integration with custom wrapper and intelligent defaults:
- Initializes charts from HTML data attributes
- **View-specific default chart types**: Bar for Time Entries, Pie for Activity and Grouping views
- Real-time chart type switching (bar ↔ line ↔ pie)
- **Context-aware data grouping**: Charts show activities in summary view, time periods in detailed view
- **Enhanced pie chart labels**: Automatic percentage and hours display (e.g., "Development (68.9%, 31.1h)")
- **Smart data detection**: Automatically detects data type (activities vs. periods) for proper formatting
- Responsive chart behavior with optimized dimensions
- Handles chart updates and interactions
- Supports multiple chart instances with proper cleanup

### Database Queries
- Efficiently queries TimeEntry model with proper joins and includes
- Cross-database compatibility (MySQL, PostgreSQL, SQLite)
- Supports filtering, pagination, and full-text search
- Activity pivot tables with optimized matrix generation
- Consistent date grouping logic across view modes
- Optimized for performance with large datasets

## Requirements

- Redmine 5.0.0 or higher
- Modern web browser with JavaScript enabled

## Key Features Highlights

### 1. Dual View System for Activity Analysis
The Activity view offers two complementary perspectives on your time data:

- **Detailed View (Default)**: 
  - Cross-tabulation pivot table showing Activity × Time Period matrix
  - Pie chart displays time periods (dates, weeks, months, or years)
  - Perfect for understanding time distribution across periods
  
- **Summary View**: 
  - Simple table showing total hours per activity
  - Pie chart displays activities with percentages and hours
  - Ideal for quick overview of where time was spent

**Toggle easily** between views using the "Show Summary View" / "Show Detailed View" button. The chart automatically updates to match your selection!

### 2. Intelligent Chart Defaults
Charts automatically select the best type for each view:
- **Time Entries View**: Bar chart (default) - ideal for comparing daily/periodic values
- **Activity View**: Pie chart (default) - perfect for showing activity distribution
- **Project View**: Pie chart (default) - great for proportional project analysis

You can still manually switch between bar, line, and pie charts using the modern custom dropdown.

### 3. Enhanced Pie Charts
All pie charts now display rich information:
- **Percentages**: See the proportion of each segment (e.g., 68.9%)
- **Hours**: View actual time spent (e.g., 31.1h)
- **Combined Labels**: "Development (68.9%, 31.1h)" provides complete context at a glance

### 4. Visual Distribution Bars
Summary tables include horizontal bar charts showing percentage distribution:
- **40% column width** for spacious, easy-to-read bars
- **Blue gradient fill** matching the plugin's color scheme
- **Percentage labels** displayed on the right side of each bar
- **Instant visual comparison** of time allocation across activities, projects, or time periods
- Available in Time Entries (grouped), Activity, and Project summary views

### 5. Flexible Time Period Filters
Choose from various time ranges:
- **Today**: Current day
- **This Week**: Current week (Monday to Sunday)
- **Last Week**: Previous week (Monday to Sunday)
- **This Month**: Current month
- **This Year**: Current year
- **Custom Range**: Select any date range

### 6. Consistent Date Formatting
All dates display in a user-friendly format:
- **Daily views**: "Dec 29, 2025"
- **Weekly views**: "12/22/2025 to 12/28/2025"
- **Monthly views**: "December 2025"
- **Yearly views**: "2025"

Consistent formatting across tables, charts, and exports ensures clarity and professionalism.

## Requirements

- Redmine 5.0.0 or higher
- Modern web browser with JavaScript enabled

## Development

### File Structure
```
redmine_time_analytics/
├── app/
│   ├── controllers/time_analytics_controller.rb
│   ├── helpers/time_analytics_helper.rb
│   └── views/time_analytics/
├── assets/
│   ├── javascripts/time_analytics_charts.js
│   └── stylesheets/time_analytics.css
├── config/
│   ├── locales/en.yml
│   └── routes.rb
├── lib/
│   └── redmine_time_analytics/
│       └── utils/
└── init.rb
```

### Recent Improvements (January 2026)

#### UI/UX Enhancements (January 2, 2026)
- **Unified Button System**: Refactored all buttons to use shared base classes for consistency
  - `.button-base`: Common button properties (transitions, border-radius, text alignment)
  - `.button-primary`: Bright blue (#007cba) for primary actions
  - `.button-secondary`: Light gray for secondary actions
  - `.button-neutral`: White background for inactive toggle states
  - Reduced CSS by 54+ lines through code reuse
- **Filter Section Improvements**: 
  - Aligned Apply and Clear buttons horizontally with other filter fields
  - Matching heights and consistent sizing across all filter controls
  - Apply button now uses primary blue color for better visual hierarchy
  - Clear button styled as secondary action with neutral gray
- **Enhanced Toggle Buttons**:
  - Increased font size to 15px with bold weight for better readability
  - Wider buttons (flex: 1) with 15px gap between each
  - Consistent blue active state matching the Apply button
- **Modern Chart Controls**:
  - Custom-styled dropdown with SVG arrow (removed browser defaults)
  - Matching heights (34px) for chart type dropdown and Hide Chart button
  - Hover and focus states with smooth transitions
  - Professional appearance matching modern design standards
- **Horizontal Distribution Bars**: Added visual percentage bars to all summary tables
  - 40% column width for spacious bar visualization
  - Blue gradient fill (#007cba to #36a2eb) with smooth animations
  - Percentage labels positioned on the right side of bars
  - Applied to: Time Entries (grouped), Activity summary, Project summary
  - Optimized table layout: left-aligned names, right-aligned hours, wide distribution column
  - Eliminates wasted space in summary views with informative visual data

#### Core Features (Early January 2026)
- **Last Week Filter**: Added "Last Week" option to time period filters for quick access to previous week's data
- **Summary View for All Groupings**: Extended summary/detailed view toggle to work with all groupings (daily, weekly, monthly, yearly)
- **Context-Aware Charts**: Pie charts now intelligently show activities in summary view and time periods in detailed view
- **View-Specific Chart Defaults**: Automatic chart type selection based on view mode (Bar for Time Entries, Pie for Activity/Project)
- **Enhanced Pie Chart Labels**: Added percentage and hours display to all pie chart segments (e.g., "Development (68.9%, 31.1h)")
- **Unified Date Formatting**: Consistent date format across tables and charts (e.g., "Dec 29, 2025")
- **Smart Chart Data Detection**: Charts automatically adapt to data type (activities vs. time periods) for proper formatting

### Previous Improvements (December 2025)
- **Optimized Layout**: Implemented side-by-side analytics layout for maximum information density
- **Compact Summary**: Redesigned statistics as 2x2 grid for better space utilization
- **Chart Optimization**: Reduced chart height and margins to eliminate empty space
- **Consistent Date Logic**: Unified Monday-Sunday week formatting across Time Entries and Activity views
- **Enhanced Responsiveness**: Improved mobile layout with proper section stacking
- **Performance**: Optimized chart rendering and reduced visual gaps

### Extending the Plugin
The plugin is designed to be extensible:
- Add new chart types by extending chart generation methods in controller
- Create new dashboard tabs by adding controller actions and views
- Extend export functionality by adding new CSV export methods
- Customize layout by modifying CSS flexbox properties in `time_analytics.css`
- Add new view modes by extending the toggle view logic

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Create a new Pull Request

## License

This plugin is licensed under the MIT License.

## Support

For issues and feature requests, please use the GitHub issue tracker.