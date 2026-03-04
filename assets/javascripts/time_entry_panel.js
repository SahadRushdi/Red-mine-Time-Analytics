/**
 * Time Entry Panel JavaScript
 * Handles inline time logging, form interactions, and real-time updates
 * 
 * @requires jQuery (Redmine core includes it)
 */

(function() {
  'use strict';

  // ============================================================================
  // STATE MANAGEMENT
  // ============================================================================
  
  const STATE = {
    openFormIssueId: null,           // Currently open form issue ID
    unsavedChanges: false,           // Track unsaved changes for navigation guard
    collapsedGroups: new Set(),      // Set of collapsed group IDs
    activeRequests: new Map()        // Track active AJAX requests
  };

  // Session storage key for collapsed groups
  const COLLAPSED_GROUPS_KEY = 'timeEntryPanel_collapsedGroups';

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

  document.addEventListener('DOMContentLoaded', function() {
    initializeCollapsedGroups();
    initializeGroupToggles();
    initializeLogTimeForms();
    initializeSearchFilter();
    initializeNavigationGuard();
    initializeFormValidation();
    
    console.log('Time Entry Panel initialized');
  });

  // ============================================================================
  // 1. GROUP COLLAPSE / EXPAND
  // ============================================================================

  /**
   * Load collapsed groups from sessionStorage
   */
  function initializeCollapsedGroups() {
    try {
      const stored = sessionStorage.getItem(COLLAPSED_GROUPS_KEY);
      if (stored) {
        const groupIds = JSON.parse(stored);
        STATE.collapsedGroups = new Set(groupIds);
        
        // Apply collapsed state to groups
        STATE.collapsedGroups.forEach(function(groupId) {
          collapseGroup(groupId, false); // false = don't save to storage again
        });
      }
    } catch (e) {
      console.warn('Failed to load collapsed groups:', e);
    }
  }

  /**
   * Save collapsed groups to sessionStorage
   */
  function saveCollapsedGroups() {
    try {
      sessionStorage.setItem(
        COLLAPSED_GROUPS_KEY, 
        JSON.stringify(Array.from(STATE.collapsedGroups))
      );
    } catch (e) {
      console.warn('Failed to save collapsed groups:', e);
    }
  }

  /**
   * Initialize click handlers for group headers
   */
  function initializeGroupToggles() {
    const groupHeaders = document.querySelectorAll('[data-toggle="collapse"]');
    
    groupHeaders.forEach(function(header) {
      header.addEventListener('click', function(e) {
        // Don't toggle if clicking a link inside the header
        if (e.target.tagName === 'A' || e.target.closest('a')) {
          return;
        }

        const targetId = header.getAttribute('data-target');
        if (!targetId) return;

        // Extract project ID from target (e.g., "#project-issues-123" -> "project-123")
        const projectId = targetId.replace('#project-issues-', 'project-');
        
        toggleGroup(projectId);
      });

      // Set cursor pointer
      header.style.cursor = 'pointer';
    });
  }

  /**
   * Toggle a project group's collapsed state
   */
  function toggleGroup(groupId) {
    if (STATE.collapsedGroups.has(groupId)) {
      expandGroup(groupId);
    } else {
      collapseGroup(groupId);
    }
  }

  /**
   * Collapse a project group
   */
  function collapseGroup(groupId, saveState = true) {
    const projectId = groupId.replace('project-', '');
    const container = document.getElementById('project-issues-' + projectId);
    const chevron = document.getElementById('chevron-' + projectId);
    
    if (!container) return;

    container.classList.add('hidden');
    if (chevron) {
      chevron.style.transform = 'rotate(-90deg)';
    }

    STATE.collapsedGroups.add(groupId);
    if (saveState) {
      saveCollapsedGroups();
    }
  }

  /**
   * Expand a project group
   */
  function expandGroup(groupId, saveState = true) {
    const projectId = groupId.replace('project-', '');
    const container = document.getElementById('project-issues-' + projectId);
    const chevron = document.getElementById('chevron-' + projectId);
    
    if (!container) return;

    container.classList.remove('hidden');
    if (chevron) {
      chevron.style.transform = 'rotate(0deg)';
    }

    STATE.collapsedGroups.delete(groupId);
    if (saveState) {
      saveCollapsedGroups();
    }
  }

  // ============================================================================
  // 2. INLINE FORM TOGGLE
  // ============================================================================

  /**
   * Initialize all Log Time buttons and form interactions
   */
  function initializeLogTimeForms() {
    // Log Time buttons
    const logTimeButtons = document.querySelectorAll('.log-time-button[data-issue-id]');
    
    logTimeButtons.forEach(function(button) {
      button.addEventListener('click', function() {
        const issueId = button.getAttribute('data-issue-id');
        toggleLogTimeForm(issueId);
      });
    });

    // Cancel buttons
    const forms = document.querySelectorAll('.time-entry-form');
    forms.forEach(function(form) {
      const issueId = form.getAttribute('data-issue-id');
      const cancelButton = form.querySelector('button[type="button"]');
      
      if (cancelButton && cancelButton.textContent.trim().toLowerCase().includes('cancel')) {
        cancelButton.addEventListener('click', function() {
          closeLogTimeForm(issueId);
        });
      }
    });

    // Track input changes for navigation guard
    const allInputs = document.querySelectorAll('.time-entry-form input, .time-entry-form select, .time-entry-form textarea');
    allInputs.forEach(function(input) {
      input.addEventListener('input', function() {
        const hoursInput = document.querySelector('.time-entry-form:not(.hidden) input[id^="hours_"]');
        if (hoursInput && hoursInput.value && parseFloat(hoursInput.value) > 0) {
          STATE.unsavedChanges = true;
        }
      });
    });
  }

  /**
   * Toggle log time form visibility
   */
  function toggleLogTimeForm(issueId) {
    const formDiv = document.getElementById('log-time-form-' + issueId);
    if (!formDiv) return;

    const isCurrentlyOpen = !formDiv.classList.contains('hidden');

    if (isCurrentlyOpen) {
      closeLogTimeForm(issueId);
    } else {
      openLogTimeForm(issueId);
    }
  }

  /**
   * Open a specific log time form
   */
  function openLogTimeForm(issueId) {
    // Close any other open forms first
    if (STATE.openFormIssueId && STATE.openFormIssueId !== issueId) {
      closeLogTimeForm(STATE.openFormIssueId);
    }

    const formDiv = document.getElementById('log-time-form-' + issueId);
    if (!formDiv) return;

    // Use max-height for smooth transition
    formDiv.classList.remove('hidden');
    formDiv.style.maxHeight = '0';
    formDiv.style.overflow = 'hidden';
    formDiv.style.transition = 'max-height 0.3s ease-out';
    
    // Trigger reflow
    formDiv.offsetHeight;
    
    // Expand
    formDiv.style.maxHeight = formDiv.scrollHeight + 'px';
    
    // Remove max-height after transition
    setTimeout(function() {
      formDiv.style.maxHeight = 'none';
      formDiv.style.overflow = 'visible';
    }, 300);

    STATE.openFormIssueId = issueId;

    // Clear any previous result messages
    const resultDiv = document.getElementById('log-result-' + issueId);
    if (resultDiv) {
      resultDiv.classList.add('hidden');
      resultDiv.innerHTML = '';
    }

    // Focus on hours input
    const hoursInput = document.getElementById('hours_' + issueId);
    if (hoursInput) {
      setTimeout(function() {
        hoursInput.focus();
      }, 350);
    }
  }

  /**
   * Close a specific log time form
   */
  function closeLogTimeForm(issueId) {
    const formDiv = document.getElementById('log-time-form-' + issueId);
    if (!formDiv) return;

    // Collapse with transition
    formDiv.style.maxHeight = formDiv.scrollHeight + 'px';
    formDiv.style.overflow = 'hidden';
    formDiv.style.transition = 'max-height 0.3s ease-in';
    
    // Trigger reflow
    formDiv.offsetHeight;
    
    // Collapse
    formDiv.style.maxHeight = '0';
    
    // Hide after transition
    setTimeout(function() {
      formDiv.classList.add('hidden');
      formDiv.style.maxHeight = '';
      formDiv.style.overflow = '';
    }, 300);

    if (STATE.openFormIssueId === issueId) {
      STATE.openFormIssueId = null;
    }

    STATE.unsavedChanges = false;
  }

  // ============================================================================
  // 3. AJAX TIME ENTRY SUBMISSION
  // ============================================================================

  /**
   * Initialize form submission handlers
   */
  function initializeFormValidation() {
    const forms = document.querySelectorAll('.time-entry-form');
    
    forms.forEach(function(form) {
      form.addEventListener('submit', function(e) {
        e.preventDefault();
        
        const issueId = form.getAttribute('data-issue-id');
        submitTimeEntry(issueId);
      });
    });
  }

  /**
   * Submit time entry via AJAX
   */
  function submitTimeEntry(issueId) {
    // Get form data
    const spentOn = document.getElementById('spent_on_' + issueId).value;
    const hours = parseFloat(document.getElementById('hours_' + issueId).value);
    const activityId = document.getElementById('activity_id_' + issueId).value;
    const comments = document.getElementById('comments_' + issueId).value;
    const authenticityToken = document.querySelector('input[name="authenticity_token"]').value;

    // Validate required fields
    if (!spentOn || !hours || hours <= 0 || !activityId) {
      showResult(issueId, 'error', 'Please fill in all required fields.');
      return;
    }

    // Get submit button and result div
    const submitButton = document.querySelector('#time-entry-form-' + issueId + ' button[type="submit"]');
    const resultDiv = document.getElementById('log-result-' + issueId);

    // Check for duplicate requests
    if (STATE.activeRequests.has(issueId)) {
      return; // Request already in progress
    }

    // Disable submit button and show loading state
    const originalButtonText = submitButton.innerHTML;
    submitButton.disabled = true;
    submitButton.innerHTML = '<svg class="inline w-4 h-4 mr-2 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg> Saving...';

    // Prepare request data
    const requestData = {
      issue_id: issueId,
      spent_on: spentOn,
      hours: hours,
      activity_id: activityId,
      comments: comments,
      authenticity_token: authenticityToken,
      // Include date range for new_total calculation
      date_from: getDateRangeFromPage().from,
      date_to: getDateRangeFromPage().to
    };

    // Track active request
    STATE.activeRequests.set(issueId, true);

    // Get CSRF token from meta tag (Redmine standard)
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    const headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    };
    
    if (csrfToken) {
      headers['X-CSRF-Token'] = csrfToken.getAttribute('content');
    }

    // Make AJAX request
    fetch('/my/time/log_time', {
      method: 'POST',
      headers: headers,
      body: JSON.stringify(requestData),
      credentials: 'same-origin'
    })
    .then(function(response) {
      return response.json().then(function(data) {
        return { status: response.status, data: data };
      });
    })
    .then(function(result) {
      STATE.activeRequests.delete(issueId);

      if (result.status === 201 && result.data.success) {
        // Success!
        handleSuccessfulSubmission(issueId, result.data);
        
        // Re-enable button with success message
        submitButton.disabled = false;
        submitButton.innerHTML = originalButtonText;
      } else {
        // Server returned an error
        const errorMessages = result.data.errors || ['An error occurred while logging time.'];
        handleSubmissionError(issueId, errorMessages.join(' '));
        
        // Re-enable button
        submitButton.disabled = false;
        submitButton.innerHTML = originalButtonText;
      }
    })
    .catch(function(error) {
      STATE.activeRequests.delete(issueId);
      console.error('Error submitting time entry:', error);
      
      handleSubmissionError(issueId, 'Network error. Please check your connection and try again.');
      
      // Re-enable button
      submitButton.disabled = false;
      submitButton.innerHTML = originalButtonText;
    });
  }

  /**
   * Handle successful time entry submission
   */
  function handleSuccessfulSubmission(issueId, responseData) {
    // Show success message
    showResult(issueId, 'success', '✓ Time logged successfully!');

    // Clear unsaved changes flag
    STATE.unsavedChanges = false;

    // Reset form fields
    resetForm(issueId);

    // Update the hours display for this issue using server's new_total
    updateIssueHoursDisplay(issueId, responseData.time_entry, responseData.new_total);

    // Dispatch custom event for other scripts to listen to
    document.dispatchEvent(new CustomEvent('timeEntryCreated', {
      detail: {
        issueId: issueId,
        timeEntry: responseData.time_entry,
        newTotal: responseData.new_total
      }
    }));

    // Close form after 1.5 seconds
    setTimeout(function() {
      closeLogTimeForm(issueId);
    }, 1500);
  }

  /**
   * Handle submission error
   */
  function handleSubmissionError(issueId, errorMessage) {
    showResult(issueId, 'error', errorMessage);
  }

  /**
   * Show result message in the form
   */
  function showResult(issueId, type, message) {
    const resultDiv = document.getElementById('log-result-' + issueId);
    if (!resultDiv) return;

    resultDiv.classList.remove('hidden');
    
    if (type === 'success') {
      resultDiv.className = 'log-result mt-4 p-3 bg-green-100 border border-green-400 text-green-700 rounded-lg text-sm font-medium';
    } else {
      resultDiv.className = 'log-result mt-4 p-3 bg-red-100 border border-red-400 text-red-700 rounded-lg text-sm font-medium';
    }
    
    resultDiv.innerHTML = message;

    // Auto-hide error messages after 5 seconds
    if (type === 'error') {
      setTimeout(function() {
        if (resultDiv.classList.contains('bg-red-100')) {
          resultDiv.classList.add('hidden');
        }
      }, 5000);
    }
  }

  /**
   * Reset form fields to defaults
   */
  function resetForm(issueId) {
    const form = document.getElementById('time-entry-form-' + issueId);
    if (!form) return;

    // Reset hours and comments
    const hoursInput = document.getElementById('hours_' + issueId);
    const commentsInput = document.getElementById('comments_' + issueId);
    
    if (hoursInput) hoursInput.value = '';
    if (commentsInput) commentsInput.value = '';

    // Reset spent_on to today (in case user changed it)
    const spentOnInput = document.getElementById('spent_on_' + issueId);
    if (spentOnInput) {
      const today = new Date();
      const year = today.getFullYear();
      const month = String(today.getMonth() + 1).padStart(2, '0');
      const day = String(today.getDate()).padStart(2, '0');
      spentOnInput.value = year + '-' + month + '-' + day;
    }
  }

  /**
   * Update the hours display for an issue after successful logging
   */
  function updateIssueHoursDisplay(issueId, timeEntry, newTotal) {
    const issueRow = document.querySelector('.issue-row[data-issue-id="' + issueId + '"]');
    if (!issueRow) return;

    const hoursDisplay = issueRow.querySelector('.text-2xl.font-bold');
    if (!hoursDisplay) return;

    // Use new_total from server response if available, otherwise calculate
    const total = newTotal !== undefined ? newTotal : (parseFloat(hoursDisplay.textContent) || 0) + parseFloat(timeEntry.hours);

    // Format and update display
    const formattedHours = formatHours(total);
    hoursDisplay.textContent = formattedHours;

    // Add a subtle animation
    hoursDisplay.style.transition = 'color 0.3s ease';
    hoursDisplay.style.color = '#16a34a'; // Green
    setTimeout(function() {
      hoursDisplay.style.color = '';
    }, 1000);
  }

  /**
   * Format hours (mimics Rails helper)
   */
  function formatHours(hours) {
    if (!hours || hours === 0) return '0.00';
    
    // Check if we should use minutes format (you can detect from page or use decimal)
    // For now, using decimal format
    return hours.toFixed(2);
  }

  // ============================================================================
  // 4. LIVE SEARCH FILTER
  // ============================================================================

  /**
   * Initialize live search functionality
   */
  function initializeSearchFilter() {
    const searchInput = document.querySelector('input[name="q"]');
    if (!searchInput) return;

    let searchTimeout;

    searchInput.addEventListener('input', function(e) {
      const searchTerm = e.target.value.toLowerCase().trim();

      // Debounce search
      clearTimeout(searchTimeout);
      searchTimeout = setTimeout(function() {
        filterIssues(searchTerm);
      }, 150);
    });

    // Also trigger on Enter key
    searchInput.addEventListener('keypress', function(e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        clearTimeout(searchTimeout);
        const searchTerm = e.target.value.toLowerCase().trim();
        filterIssues(searchTerm);
      }
    });
  }

  /**
   * Filter issues based on search term
   */
  function filterIssues(searchTerm) {
    const allIssueRows = document.querySelectorAll('.issue-row');
    const allProjectGroups = document.querySelectorAll('.project-group');

    if (!searchTerm) {
      // Show all issues and groups
      allIssueRows.forEach(function(row) {
        row.style.display = '';
      });
      allProjectGroups.forEach(function(group) {
        group.style.display = '';
      });
      return;
    }

    // Filter issue rows
    allIssueRows.forEach(function(row) {
      const issueId = row.getAttribute('data-issue-id');
      const subject = row.querySelector('h4')?.textContent.toLowerCase() || '';
      const issueIdText = '#' + issueId;

      if (subject.includes(searchTerm) || issueIdText.includes(searchTerm)) {
        row.style.display = '';
      } else {
        row.style.display = 'none';
      }
    });

    // Hide groups with no visible issues
    allProjectGroups.forEach(function(group) {
      const groupId = group.getAttribute('data-group-id');
      const projectId = groupId.replace('project-', '');
      const issuesContainer = document.getElementById('project-issues-' + projectId);
      
      if (!issuesContainer) {
        group.style.display = 'none';
        return;
      }

      // Count visible issues in this group
      const visibleIssues = issuesContainer.querySelectorAll('.issue-row:not([style*="display: none"])');
      
      if (visibleIssues.length === 0) {
        group.style.display = 'none';
      } else {
        group.style.display = '';
      }
    });
  }

  // ============================================================================
  // 5. BACK NAVIGATION GUARD
  // ============================================================================

  /**
   * Initialize navigation guard for unsaved changes
   */
  function initializeNavigationGuard() {
    window.addEventListener('beforeunload', function(e) {
      if (STATE.unsavedChanges) {
        const message = 'You have an unsaved time entry. Leave anyway?';
        e.preventDefault();
        e.returnValue = message; // Standard for most browsers
        return message; // For older browsers
      }
    });
  }

  // ============================================================================
  // GLOBAL FUNCTIONS (for inline onclick handlers)
  // ============================================================================

  // Expose functions to global scope for inline handlers
  window.toggleProjectGroup = function(projectId) {
    toggleGroup('project-' + projectId);
  };

  window.toggleLogTimeForm = function(issueId) {
    toggleLogTimeForm(issueId);
  };

  window.submitLogTime = function(event, issueId) {
    event.preventDefault();
    submitTimeEntry(issueId);
  };

  // ============================================================================
  // UTILITY FUNCTIONS
  // ============================================================================

  /**
   * Debounce function
   */
  function debounce(func, wait) {
    let timeout;
    return function executedFunction() {
      const context = this;
      const args = arguments;
      clearTimeout(timeout);
      timeout = setTimeout(function() {
        func.apply(context, args);
      }, wait);
    };
  }

  /**
   * Get date range from page header or URL params
   */
  function getDateRangeFromPage() {
    // Try to get from URL params first
    const urlParams = new URLSearchParams(window.location.search);
    const dateFrom = urlParams.get('date_from');
    const dateTo = urlParams.get('date_to');
    
    if (dateFrom && dateTo) {
      return { from: dateFrom, to: dateTo };
    }
    
    // Fallback to current week
    const today = new Date();
    const monday = new Date(today);
    monday.setDate(today.getDate() - (today.getDay() || 7) + 1);
    const sunday = new Date(monday);
    sunday.setDate(monday.getDate() + 6);
    
    return {
      from: monday.toISOString().split('T')[0],
      to: sunday.toISOString().split('T')[0]
    };
  }

})();
