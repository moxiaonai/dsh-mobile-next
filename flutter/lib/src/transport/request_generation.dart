/// Source-owned asynchronous UI requests. Old outcomes cannot commit or cancel
/// their successor; resources returned by an old success must be disposed.
class RequestGeneration {
  int _current = 0;
  int begin() => ++_current;
  bool owns(int generation) => generation == _current;
  bool cancel(int generation) {
    if (!owns(generation)) return false;
    ++_current;
    return true;
  }
  void invalidate() => ++_current;
}
