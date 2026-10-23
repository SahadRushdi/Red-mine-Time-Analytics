// Core replaces the custom-field form over AJAX when its format changes. Observe replacement
// and delegate changes so the grouping/filter controls also work on the refreshed form.
(function () {
  function updateControls() {
    var control = document.getElementById('ta-pinned-grouping-control');
    if (!control) { return; }
    var form = control.closest('form');
    if (!form) { return; }
    var format = form.querySelector('#custom_field_field_format');
    var multiple = form.querySelector('#custom_field_multiple');
    var filter = form.querySelector('#custom_field_is_filter');
    var pin = form.querySelector('#ta_pinned_grouping');
    var unchecked = form.querySelector('#ta-pinned-grouping-unchecked');
    var formats = JSON.parse(control.getAttribute('data-grouping-formats'));
    var multipleFormats = JSON.parse(control.getAttribute('data-multiple-grouping-formats') || '[]');
    var supported = !!(format && formats.indexOf(format.value) !== -1 &&
      (!(multiple && multiple.checked) || multipleFormats.indexOf(format.value) !== -1) && filter);

    control.hidden = !supported;
    if (filter) {
      filter.closest('p').hidden = !supported;
      // Disabled inputs (including Rails' unchecked value) preserve the existing filter
      // configuration when the controls are hidden.
      form.querySelectorAll('input[name="custom_field[is_filter]"]').forEach(function (input) {
        input.disabled = !supported;
      });
    }
    var eligible = supported && filter.checked;
    if (pin) { pin.disabled = !eligible; }
    if (unchecked) { unchecked.disabled = !eligible; }
    var hint = control.querySelector('em');
    if (hint) { hint.hidden = eligible; }
  }

  document.addEventListener('change', function (event) {
    if (/^(custom_field_field_format|custom_field_multiple|custom_field_is_filter)$/.test(event.target.id)) {
      updateControls();
    }
  });
  document.addEventListener('DOMContentLoaded', function () {
    updateControls();
    new MutationObserver(updateControls).observe(document.getElementById('content') || document.body,
      { childList: true, subtree: true });
  });
}());
