var TimeAnalytics = TimeAnalytics || {};

// Chart instance tracking
TimeAnalytics.chartInstances = {};

// Initialize all charts on the page
TimeAnalytics.initCharts = function() {
  var chartElements = document.querySelectorAll('.chart[data-chart]');
  
  chartElements.forEach(function(element) {
    try {
      // Destroy existing chart if it exists
      if (TimeAnalytics.chartInstances[element.id]) {
        TimeAnalytics.chartInstances[element.id].destroy();
      }
      
      var chartConfig = JSON.parse(element.getAttribute('data-chart'));
      
      // Create gradient for bar charts
      if (chartConfig.type === 'bar' && chartConfig.data.datasets[0].backgroundColor === 'GRADIENT_PLACEHOLDER') {
        var ctx = element.getContext('2d');
        var gradient = ctx.createLinearGradient(0, 0, 0, element.height);
        gradient.addColorStop(0, '#007cba');
        gradient.addColorStop(1, '#36a2eb');
        chartConfig.data.datasets[0].backgroundColor = gradient;
      }
      
      // Ensure responsive configuration
      if (!chartConfig.options) {
        chartConfig.options = {};
      }
      chartConfig.options.responsive = true;
      chartConfig.options.maintainAspectRatio = false;
      
      // Add default tooltip formatting for time data
      if (!chartConfig.options.plugins) {
        chartConfig.options.plugins = {};
      }
      
      if (!chartConfig.options.plugins.tooltip) {
        chartConfig.options.plugins.tooltip = {
          callbacks: {
            label: function(context) {
              var label = context.dataset.label || '';
              if (label) {
                label += ': ';
              }
              
              var value = context.parsed.y !== null ? context.parsed.y : context.parsed;
              
              // Format hours with 2 decimal places
              if (typeof value === 'number') {
                label += value.toFixed(2) + 'h';
              } else {
                label += value;
              }
              
              return label;
            }
          }
        };
      }
      
      // Create new chart instance
      var chart = new Chart(element, chartConfig);
      
      // Store chart instance for later reference
      if (element.id) {
        TimeAnalytics.chartInstances[element.id] = chart;
        
        // Special handling for main time chart
        if (element.id === 'time-chart') {
          window.timeAnalyticsChart = chart;
        }
      }
      
    } catch (e) {
      element.innerHTML = '<div class="error-message">Error loading chart</div>';
    }
  });
};

// Update chart with new data
TimeAnalytics.updateChart = function(elementId, newConfig) {
  var element = document.getElementById(elementId);
  if (!element) return;
  
  // Destroy existing chart
  if (TimeAnalytics.chartInstances[elementId]) {
    TimeAnalytics.chartInstances[elementId].destroy();
    delete TimeAnalytics.chartInstances[elementId];
  }
  
  // Update data attribute
  element.setAttribute('data-chart', JSON.stringify(newConfig));
  
  // Reinitialize chart
  TimeAnalytics.initCharts();
};

// Export chart as image
TimeAnalytics.exportChart = function(chartId, filename) {
  var chart = TimeAnalytics.chartInstances[chartId];
  if (!chart) return;
  
  var canvas = chart.canvas;
  var url = canvas.toDataURL('image/png');
  
  var link = document.createElement('a');
  link.href = url;
  link.download = filename || 'chart.png';
  link.click();
};

// Resize all charts (useful for responsive layouts)
TimeAnalytics.resizeCharts = function() {
  Object.keys(TimeAnalytics.chartInstances).forEach(function(chartId) {
    TimeAnalytics.chartInstances[chartId].resize();
  });
};

// Chart color schemes
TimeAnalytics.colorSchemes = {
  default: [
    '#FF6384', '#36A2EB', '#FFCE56', '#4BC0C0', '#9966FF',
    '#FF9F40', '#8AC249', '#EA5F89', '#00D1B2', '#958AF7'
  ],
  blue: ['#E3F2FD', '#BBDEFB', '#90CAF9', '#64B5F6', '#42A5F5', '#2196F3', '#1E88E5', '#1976D2', '#1565C0', '#0D47A1'],
  green: ['#E8F5E8', '#C8E6C9', '#A5D6A7', '#81C784', '#66BB6A', '#4CAF50', '#43A047', '#388E3C', '#2E7D32', '#1B5E20'],
  warm: ['#FFF3E0', '#FFE0B2', '#FFCC80', '#FFB74D', '#FFA726', '#FF9800', '#FB8C00', '#F57C00', '#EF6C00', '#E65100']
};

// Apply color scheme to chart config
TimeAnalytics.applyColorScheme = function(chartConfig, schemeName) {
  var colors = TimeAnalytics.colorSchemes[schemeName] || TimeAnalytics.colorSchemes.default;
  
  if (chartConfig.data && chartConfig.data.datasets) {
    chartConfig.data.datasets.forEach(function(dataset, index) {
      if (chartConfig.type === 'bar') {
        // Use placeholder for gradient (will be replaced during init)
        dataset.backgroundColor = 'GRADIENT_PLACEHOLDER';
        dataset.borderColor = '#007cba';
      } else if (chartConfig.type === 'line') {
        dataset.backgroundColor = 'rgba(54, 162, 235, 0.1)';
        dataset.borderColor = '#36a2eb';
      }
    });
  }
  
  return chartConfig;
};

// Utility function to format hours
TimeAnalytics.formatHours = function(hours) {
  if (typeof hours !== 'number') return '0.00h';
  return hours.toFixed(2) + 'h';
};

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', function() {
  // Initialize charts if they exist
  if (document.querySelectorAll('.chart[data-chart]').length > 0) {
    TimeAnalytics.initCharts();
  }
  
  // Handle window resize
  window.addEventListener('resize', function() {
    setTimeout(function() {
      TimeAnalytics.resizeCharts();
    }, 100);
  });
});

// Export for global access
window.TimeAnalytics = TimeAnalytics;