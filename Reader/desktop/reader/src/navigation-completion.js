// A deadline cannot release a navigation lease: Readium may still be active.
// Only its callback or disposal of that specific navigator ends the operation.
export class NavigationCompletion {
  pending = new Map();
  disposed = new WeakSet();

  wait(owner, start, completed = () => {}) {
    if (this.disposed.has(owner)) return Promise.resolve(false);
    return new Promise((resolve, reject) => {
      let settled = false;
      let operations = this.pending.get(owner);
      if (!operations) this.pending.set(owner, operations = new Set());
      const finish = (moved, cancelled = false, error) => {
        if (settled) return;
        settled = true;
        operations.delete(cancel);
        if (!operations.size) this.pending.delete(owner);
        if (error) { reject(error); return; }
        try {
          if (!cancelled) completed(moved === true);
          resolve(!cancelled && moved === true);
        } catch (error) { reject(error); }
      };
      const cancel = () => finish(false, true);
      operations.add(cancel);
      try { start(moved => finish(moved)); }
      catch (error) { finish(false, true, error); }
    });
  }

  dispose(owner) {
    if (!owner) return;
    this.disposed.add(owner);
    for (const cancel of this.pending.get(owner) ?? []) cancel();
  }
}
