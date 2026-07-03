// Shared drag-and-drop "board" for mapping Activities into named Groups.
// Used by both the Administration -> Activity Groups page (persistImmediately: true, mutations
// are POSTed to the server) and the Team Dashboard's session-only "Customize groups" popup
// (persistImmediately: false, mutations only touch an in-memory working copy).
//
// options:
//   groups:        [{ id, name, color, position }]
//   activities:    [{ id, name }]
//   assignments:   { activityId: groupId|null }
//   ungroupedColor: '#9CA3AF' (optional)
//   persistImmediately: boolean
//   onAssign(activityId, groupIdOrNull)      -> optional Promise; rejection reverts local state
//   onAddGroup(name)                          -> returns a group object, or a Promise resolving to one
//   onRemoveGroup(groupId)                    -> optional Promise; rejection reverts local state
//   onRenameGroup(groupId, name)              -> optional Promise; rejection reverts local state
//   onReorderGroups(orderedGroupIds)          -> optional Promise; rejection reverts local state
(function (window) {
  'use strict';

  var UNGROUPED_ID = '__ungrouped__';

  function TaActivityGroupBoard(rootEl, options) {
    var state = {
      groups: (options.groups || []).map(cloneGroup).sort(byPosition),
      activities: (options.activities || []).slice(),
      assignments: shallowCopy(options.assignments || {})
    };

    var ungroupedColor = options.ungroupedColor || '#9CA3AF';

    function cloneGroup(g) {
      return { id: String(g.id), name: g.name, color: g.color, position: g.position || 0 };
    }

    function byPosition(a, b) { return a.position - b.position; }

    function shallowCopy(obj) {
      var out = {};
      Object.keys(obj).forEach(function (k) { out[k] = obj[k] === null || obj[k] === undefined ? null : String(obj[k]); });
      return out;
    }

    function activitiesFor(groupId) {
      return state.activities.filter(function (a) {
        var assigned = state.assignments[String(a.id)];
        return groupId === UNGROUPED_ID ? !assigned : assigned === String(groupId);
      });
    }

    function escapeHtml(str) {
      return String(str == null ? '' : str).replace(/[&<>"']/g, function (c) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
      });
    }

    function chipHtml(activity) {
      return '<div class="ta-chip" draggable="true" data-activity-id="' + activity.id + '">' +
        escapeHtml(activity.name) + '</div>';
    }

    function groupColumnHtml(group) {
      var chips = activitiesFor(group.id).map(chipHtml).join('');
      return (
        '<div class="ta-group-column" data-group-id="' + group.id + '">' +
          '<div class="ta-group-dropzone-header" draggable="true" data-group-id="' + group.id + '">' +
            '<span class="ta-group-dot" style="background-color:' + group.color + ';"></span>' +
            '<span class="ta-group-name" data-group-id="' + group.id + '" title="Click to rename">' + escapeHtml(group.name) + '</span>' +
            '<button type="button" class="ta-group-remove" data-group-id="' + group.id + '" aria-label="Remove group">&times;</button>' +
          '</div>' +
          '<div class="ta-group-dropzone" data-group-id="' + group.id + '">' + chips + '</div>' +
        '</div>'
      );
    }

    function ungroupedColumnHtml() {
      var chips = activitiesFor(UNGROUPED_ID).map(chipHtml).join('');
      return (
        '<div class="ta-group-column ta-group-column-ungrouped" data-group-id="' + UNGROUPED_ID + '">' +
          '<div class="ta-group-dropzone-header ta-group-dropzone-header-static">' +
            '<span class="ta-group-dot" style="background-color:' + ungroupedColor + ';"></span>' +
            '<span class="ta-group-name">Ungrouped</span>' +
          '</div>' +
          '<div class="ta-group-dropzone" data-group-id="' + UNGROUPED_ID + '">' + chips + '</div>' +
        '</div>'
      );
    }

    function render() {
      var html = state.groups.map(groupColumnHtml).join('') + ungroupedColumnHtml() +
        '<div class="ta-group-add-column">' +
          '<button type="button" class="ta-group-add-btn">+ Add group</button>' +
        '</div>';
      rootEl.innerHTML = html;
      wireEvents();
    }

    function withRevert(promise, onFail) {
      if (promise && typeof promise.then === 'function') {
        promise.catch(function (err) {
          onFail();
          render();
          if (err && err.message) { window.alert(err.message); }
        });
      }
    }

    function assignActivity(activityId, groupId) {
      var previous = state.assignments[String(activityId)] || null;
      state.assignments[String(activityId)] = groupId;
      render();

      if (options.onAssign) {
        withRevert(options.onAssign(activityId, groupId), function () {
          state.assignments[String(activityId)] = previous;
        });
      }
    }

    function removeGroup(groupId) {
      var previousGroups = state.groups.slice();
      var previousAssignments = shallowCopy(state.assignments);

      state.groups = state.groups.filter(function (g) { return g.id !== String(groupId); });
      Object.keys(state.assignments).forEach(function (activityId) {
        if (state.assignments[activityId] === String(groupId)) { state.assignments[activityId] = null; }
      });
      render();

      if (options.onRemoveGroup) {
        withRevert(options.onRemoveGroup(groupId), function () {
          state.groups = previousGroups;
          state.assignments = previousAssignments;
        });
      }
    }

    function renameGroup(groupId, name) {
      name = (name || '').trim();
      if (!name) { render(); return; }

      var group = state.groups.filter(function (g) { return g.id === String(groupId); })[0];
      if (!group) { return; }
      var previousName = group.name;
      group.name = name;
      render();

      if (options.onRenameGroup) {
        withRevert(options.onRenameGroup(groupId, name), function () { group.name = previousName; });
      }
    }

    function addGroup(name) {
      name = (name || '').trim();
      if (!name) { return; }

      if (options.onAddGroup) {
        var result = options.onAddGroup(name);
        if (result && typeof result.then === 'function') {
          result.then(function (group) {
            state.groups.push(cloneGroup(group));
            render();
          }).catch(function (err) {
            render();
            if (err && err.message) { window.alert(err.message); }
          });
          return;
        }
        if (result) {
          state.groups.push(cloneGroup(result));
          render();
          return;
        }
      }

      state.groups.push({
        id: 'local-' + Date.now() + '-' + Math.floor(Math.random() * 1000),
        name: name,
        color: ungroupedColor,
        position: state.groups.length
      });
      render();
    }

    function reorderGroups(draggedId, targetId) {
      if (draggedId === targetId) { return; }
      var ids = state.groups.map(function (g) { return g.id; });
      var from = ids.indexOf(String(draggedId));
      var to = ids.indexOf(String(targetId));
      if (from === -1 || to === -1) { return; }

      var previousGroups = state.groups.slice();
      var reordered = state.groups.slice();
      var moved = reordered.splice(from, 1)[0];
      reordered.splice(to, 0, moved);
      reordered.forEach(function (g, index) { g.position = index; });
      state.groups = reordered;
      render();

      if (options.onReorderGroups) {
        withRevert(options.onReorderGroups(reordered.map(function (g) { return g.id; })), function () {
          state.groups = previousGroups;
        });
      }
    }

    function wireEvents() {
      rootEl.querySelectorAll('.ta-chip[draggable="true"]').forEach(function (chip) {
        chip.addEventListener('dragstart', function (event) {
          chip.classList.add('ta-dragging');
          event.dataTransfer.effectAllowed = 'move';
          event.dataTransfer.setData('application/x-ta-chip', chip.getAttribute('data-activity-id'));
        });
        chip.addEventListener('dragend', function () {
          chip.classList.remove('ta-dragging');
          rootEl.querySelectorAll('.ta-dropzone-hover').forEach(function (z) { z.classList.remove('ta-dropzone-hover'); });
        });
      });

      rootEl.querySelectorAll('.ta-group-dropzone').forEach(function (zone) {
        zone.addEventListener('dragover', function (event) {
          if (event.dataTransfer.types.indexOf('application/x-ta-chip') === -1) { return; }
          event.preventDefault();
          event.dataTransfer.dropEffect = 'move';
          zone.classList.add('ta-dropzone-hover');
        });
        zone.addEventListener('dragenter', function (event) {
          if (event.dataTransfer.types.indexOf('application/x-ta-chip') === -1) { return; }
          event.preventDefault();
          zone.classList.add('ta-dropzone-hover');
        });
        zone.addEventListener('dragleave', function (event) {
          var related = event.relatedTarget;
          if (!related || !zone.contains(related)) { zone.classList.remove('ta-dropzone-hover'); }
        });
        zone.addEventListener('drop', function (event) {
          var activityId = event.dataTransfer.getData('application/x-ta-chip');
          if (!activityId) { return; }
          event.preventDefault();
          zone.classList.remove('ta-dropzone-hover');
          var groupId = zone.getAttribute('data-group-id');
          assignActivity(activityId, groupId === UNGROUPED_ID ? null : groupId);
        });
      });

      rootEl.querySelectorAll('.ta-group-dropzone-header[draggable="true"]').forEach(function (header) {
        header.addEventListener('dragstart', function (event) {
          event.stopPropagation();
          event.dataTransfer.effectAllowed = 'move';
          event.dataTransfer.setData('application/x-ta-group-reorder', header.getAttribute('data-group-id'));
        });
        header.addEventListener('dragover', function (event) {
          if (event.dataTransfer.types.indexOf('application/x-ta-group-reorder') === -1) { return; }
          event.preventDefault();
          event.stopPropagation();
          header.classList.add('ta-group-header-hover');
        });
        header.addEventListener('dragleave', function () { header.classList.remove('ta-group-header-hover'); });
        header.addEventListener('drop', function (event) {
          var draggedId = event.dataTransfer.getData('application/x-ta-group-reorder');
          if (!draggedId) { return; }
          event.preventDefault();
          event.stopPropagation();
          header.classList.remove('ta-group-header-hover');
          reorderGroups(draggedId, header.getAttribute('data-group-id'));
        });
      });

      rootEl.querySelectorAll('.ta-group-remove').forEach(function (btn) {
        btn.addEventListener('click', function () {
          if (window.confirm('Remove this group? Its activities will become Ungrouped.')) {
            removeGroup(btn.getAttribute('data-group-id'));
          }
        });
      });

      rootEl.querySelectorAll('.ta-group-name[data-group-id]').forEach(function (label) {
        label.addEventListener('click', function () {
          var groupId = label.getAttribute('data-group-id');
          var input = document.createElement('input');
          input.type = 'text';
          input.className = 'ta-group-name-input';
          input.value = label.textContent;
          label.replaceWith(input);
          input.focus();
          input.select();

          function commit() { renameGroup(groupId, input.value); }
          input.addEventListener('blur', commit);
          input.addEventListener('keydown', function (event) {
            if (event.key === 'Enter') { input.blur(); }
            if (event.key === 'Escape') { input.value = label.textContent; input.blur(); }
          });
        });
      });

      var addBtn = rootEl.querySelector('.ta-group-add-btn');
      if (addBtn) {
        addBtn.addEventListener('click', function () {
          var name = window.prompt('New group name:');
          if (name) { addGroup(name); }
        });
      }
    }

    render();

    return {
      render: render,
      getState: function () {
        return { groups: state.groups.map(cloneGroup), assignments: shallowCopy(state.assignments) };
      },
      reset: function (newGroups, newAssignments) {
        state.groups = (newGroups || []).map(cloneGroup).sort(byPosition);
        state.assignments = shallowCopy(newAssignments || {});
        render();
      }
    };
  }

  window.TaActivityGroupBoard = TaActivityGroupBoard;
})(window);
