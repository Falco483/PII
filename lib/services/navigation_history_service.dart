import 'package:flutter/foundation.dart';

/// Represents a single entry in the navigation history stack.
/// [T] is the type of the state enum (e.g. NavigationAppState).
class NavigationHistoryEntry<T> {
  final T state;
  final Map<String, dynamic>? data;

  NavigationHistoryEntry(this.state, [this.data]);
}

/// A centralized service to manage the back stack history for single-page apps
/// driven by an internal state machine (like NavigationAppState).
/// Works identically on Android and iOS.
class NavigationHistoryService<T> extends ChangeNotifier {
  final List<NavigationHistoryEntry<T>> _stack = [];

  /// The current full history stack.
  List<NavigationHistoryEntry<T>> get stack => List.unmodifiable(_stack);

  /// Whether there is a previous screen to go back to.
  bool get canGoBack => _stack.length > 1;

  /// The current active state in the history.
  NavigationHistoryEntry<T>? get currentState => _stack.isNotEmpty ? _stack.last : null;

  /// Pushes a new state into the history stack.
  /// If the new state is the same as the current state, it is ignored
  /// to prevent duplicate consecutive entries.
  void pushState(T state, {Map<String, dynamic>? data}) {
    if (_stack.isNotEmpty && _stack.last.state == state) {
      return; 
    }
    
    _stack.add(NavigationHistoryEntry<T>(state, data));
    notifyListeners();
  }

  /// Removes the current state and returns the previous state entry.
  /// Returns null if the stack is empty or at the root state.
  NavigationHistoryEntry<T>? goBack() {
    if (!canGoBack) return null;
    
    _stack.removeLast(); // Remove current state
    notifyListeners();
    return _stack.last; // Return new state to be loaded
  }

  /// Updates the data snapshot of the top entry WITHOUT pushing a new entry.
  ///
  /// Use case: after calculating a route while in [placeSelected], the
  /// directions/allRoutes data has changed. We need to update the existing
  /// entry so that going back restores the fresh data instead of the stale
  /// placeholder that was stored when the entry was first pushed.
  void updateTopData(Map<String, dynamic>? data) {
    if (_stack.isEmpty) return;
    final top = _stack.last;
    _stack[_stack.length - 1] = NavigationHistoryEntry<T>(top.state, data);
    // No notifyListeners — the state itself hasn't changed, only the snapshot.
  }

  /// Resets the history stack to a single root state.
  void clearToRoot(T rootState, {Map<String, dynamic>? data}) {
    _stack.clear();
    _stack.add(NavigationHistoryEntry<T>(rootState, data));
    notifyListeners();
  }
}
