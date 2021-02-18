module concurrency.operations.race;

import concurrency;
import concurrency.receiver;
import concurrency.sender;
import concurrency.stoptoken;
import concepts;
import std.traits;

/// Runs both Senders and propagates the value of whoever completes first
/// if both error out the first exception is propagated,
/// uses mir.algebraic if the Sender value types differ
RaceSender!(SenderA, SenderB) race(SenderA, SenderB)(SenderA senderA, SenderB senderB) {
  return RaceSender!(SenderA, SenderB)(senderA, senderB);
}

private template Result(SenderA, SenderB) {
  import mir.algebraic : Algebraic, Nullable;
  static if (is(SenderA.Value == void) && is(SenderB.Value == void))
    alias Result = void;
  else static if (is(SenderA.Value == void))
    alias Result = Nullable!(SenderB.Value);
  else static if (is(SenderB.Value == void))
    alias Result = Nullable!(SenderA.Value);
  else static if (is(SenderA.Value == SenderB.Value))
    alias Result = SenderA.Value;
  else
    alias Result = Algebraic!(SenderA.Value, SenderB.Value);
}

private struct RaceOp(Receiver, SenderA, SenderB) {
  Receiver receiver;
  SenderA senderA;
  SenderB senderB;
  void start() @trusted {
    import concurrency.stoptoken : StopSource;
    if (receiver.getStopToken().isStopRequested) {
      receiver.setDone();
      return;
    }
    auto state = new State!(Result!(SenderA, SenderB))();
    state.cb = receiver.getStopToken().onStop(cast(void delegate() nothrow @safe shared)&state.stop); // butt ugly cast, but it won't take the second overload
    senderA.connect(RaceReceiver!(Receiver, SenderA.Value, Result!(SenderA, SenderB))(receiver, state, 2)).start();
    senderB.connect(RaceReceiver!(Receiver, SenderB.Value, Result!(SenderA, SenderB))(receiver, state, 2)).start();
  }
}

private struct RaceSender(SenderA, SenderB) {
  alias Value = Result!(SenderA, SenderB);
  SenderA senderA;
  SenderB senderB;
  auto connect(Receiver)(Receiver receiver) {
    return RaceOp!(Receiver, SenderA, SenderB)(receiver, senderA, senderB);
  }
}

private class State(Value) : StopSource {
  StopCallback cb;
  static if (!is(Value == void))
    Value value;
  Exception exception;
  shared size_t racestate;
}

private void spin_yield() nothrow @trusted @nogc {
  // TODO: could use the pause asm instruction
  // it is available in LDC as intrinsic... but not in DMD
  import core.thread : Thread;

  Thread.yield();
}

/// ugly ugly
static if (__traits(compiles, () { import core.atomic : casWeak; }) && __traits(compiles, () {
      import core.internal.atomic : atomicCompareExchangeWeakNoResult;
    }))
  import core.atomic : casWeak;
 else {
   import core.atomic : MemoryOrder;
   auto casWeak(MemoryOrder M1, MemoryOrder M2, T, V1, V2)(T* here, V1 ifThis, V2 writeThis) pure nothrow @nogc @safe {
     import core.atomic : cas;

     static if (__traits(compiles, cas!(M1, M2)(here, ifThis, writeThis)))
       return cas!(M1, M2)(here, ifThis, writeThis);
     else
       return cas(here, ifThis, writeThis);
   }
 }

private enum Flags : size_t {
  locked = 0x1,
  value_produced = 0x2,
  exception_produced = 0x4
}

private enum Counter : size_t {
  tick = 0x8,
  mask = ~0x7
}

private struct RaceReceiver(Receiver, InnerValue, Value) {
  import core.atomic : atomicOp, atomicLoad, MemoryOrder;
  Receiver receiver;
  State!(Value) state;
  size_t senderCount;
  auto getStopToken() {
    return StopToken(state);
  }
  private void setReceiverValue() nothrow {
    import concurrency.receiver : setValueOrError;
    static if (is(Value == void))
      receiver.setValueOrError();
    else
      receiver.setValueOrError(state.value);
  }
  private auto update(size_t transition) nothrow {
    import std.typecons : tuple;
    size_t oldState, newState;
    do {
      goto load_state;
      do {
        spin_yield();
      load_state:
        oldState = state.racestate.atomicLoad!(MemoryOrder.acq);
      } while (isLocked(oldState));
      newState = (oldState + Counter.tick) | transition;
    } while (!casWeak!(MemoryOrder.acq, MemoryOrder.acq)(&state.racestate, oldState, newState));
    return tuple!("old", "new_")(oldState, newState);
  }
  private bool isValueProduced(size_t state) {
    return (state & Flags.value_produced) > 0;
  }
  private bool isExceptionProduced(size_t state) {
    return (state & Flags.exception_produced) > 0;
  }
  private bool isLocked(size_t state) {
    return (state & Flags.locked) > 0;
  }
  private bool isLast(size_t state) {
    return (state >> 3) == senderCount;
  }
  static if (!is(InnerValue == void))
    void setValue(InnerValue value) {
      auto transition = update(Flags.value_produced | Flags.locked);
      if (!isValueProduced(transition.old)) {
        state.value = Value(value);
        state.racestate.atomicOp!"-="(Flags.locked); // need to unlock before stop
        state.stop();
      } else
        state.racestate.atomicOp!"-="(Flags.locked);

      if (isLast(transition.new_)) {
        setReceiverValue();
        state.cb.dispose();
      }
    }
  else
    void setValue() {
      auto transition = update(Flags.value_produced);
      if (!isValueProduced(transition.old)) {
        state.stop();
      }
      if (isLast(transition.new_)) {
        setReceiverValue();
        state.cb.dispose();
      }
    }
  void setDone() {
    auto transition = update(0);
    if (isLast(transition.new_)) {
      if (isValueProduced(transition.new_))
        setReceiverValue();
      else if (state.isStopRequested())
        receiver.setDone();
      else if (isExceptionProduced(transition.new_))
        receiver.setError(state.exception);
      else
        receiver.setDone();
      state.cb.dispose();
    }
  }
  void setError(Exception exception) {
    auto transition = update(Flags.exception_produced | Flags.locked);
    if (!isExceptionProduced(transition.old)) {
      state.exception = exception;
    }
    state.racestate.atomicOp!"-="(Flags.locked);

    if (isLast(transition.new_)) {
      if (isValueProduced(transition.new_))
        setReceiverValue();
      else if (state.isStopRequested())
        receiver.setDone();
      else
        receiver.setError(state.exception);
      state.cb.dispose();
    }
  }
}