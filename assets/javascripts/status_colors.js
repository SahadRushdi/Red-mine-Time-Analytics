/**
 * StatusColors - Automatic coloring for status badges based on their text content.
 * Generates consistent, visually pleasing HSL colors for any status name.
 */
(function() {
  const StatusColors = {
    /**
     * Hashes a string into a numeric value.
     */
    getHash: function(str) {
      let hash = 0;
      for (let i = 0; i < str.length; i++) {
        hash = str.charCodeAt(i) + ((hash << 5) - hash);
      }
      return hash;
    },

    /**
     * Generates a consistent HSL color based on the hash of the string.
     * Uses fixed saturation and lightness for a uniform look (soft backgrounds, dark text).
     */
    generateColor: function(str) {
      const hash = this.getHash(str);
      const h = Math.abs(hash % 360);
      
      // Fixed values for a consistent, professional "badge" look
      // Saturation: 65% for enough color, Lightness: 90% for a soft pastel background
      // Text Lightness: 30% for high contrast
      return {
        background: `hsl(${h}, 65%, 90%)`,
        text: `hsl(${h}, 70%, 25%)`
      };
    },

    /**
     * Applies automatic coloring to all status and tracker badges on the page.
     */
    apply: function() {
      const badges = document.querySelectorAll('.ts-status-badge, .ts-tracker-badge');
      badges.forEach(badge => {
        const text = badge.textContent.trim();
        if (text) {
          const colors = this.generateColor(text);
          badge.style.backgroundColor = colors.background;
          badge.style.color = colors.text;
          // Add a subtle border matching the color
          badge.style.borderColor = colors.text.replace('25%)', '80%)'); 
          badge.style.borderWidth = '1px';
          badge.style.borderStyle = 'solid';
        }
      });
    }
  };

  // Expose globally
  window.StatusColors = StatusColors;

  // Run on DOM load
  document.addEventListener('DOMContentLoaded', () => {
    StatusColors.apply();
  });
  
  // Also run if the page is already loaded
  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    StatusColors.apply();
  }
})();
