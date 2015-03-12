load 'quickstart3.rb'
require 'eventmachine'

class DefaultHandler < RethinkDB::Handler
  attr_accessor :state
  def initialize; @state = []; end
  def on_error(err)
    @state << [:err, err]
  end
  def on_val(val)
    @state << [:val, val]
  end
end

class ValTypeHandler < RethinkDB::Handler
  attr_accessor :state
  def initialize; @state = []; end
  def on_error(err)
    @state << [:err, err]
  end
  def on_atom(val)
    @state << [:atom, val]
  end
  def on_stream_val(val)
    @state << [:stream_val, val]
  end
end

class ValTypeHandler2 < ValTypeHandler
  def on_array(val)
    on_atom(val)
  end
end

class ChangeOnlyHandler < RethinkDB::Handler
  attr_accessor :state
  def initialize; @state = []; end
  def on_error(err)
    @state << [:err, err]
  end
  def on_change(old_val, new_val)
    @state << [:change, old_val, new_val]
  end
end

class ChangeHandler < ValTypeHandler2
  def on_change(old_val, new_val)
    @state << [:change, old_val, new_val]
  end
end

class CleverChangeHandler < ChangeHandler
  def on_state(state)
    @state << [:state, state]
  end
  def on_initial_val(initial_val)
    @state << [:initial_val, initial_val]
  end
end

def run1(x, handler)
  x.em_run(handler)
end
def run2(x, handler)
  x.em_run($c, handler)
end
def run3(x, handler)
  x.em_run($c, {durability: 'soft'}, handler)
end
def run4(x, handler)
  x.em_run({durability: 'soft'}, handler)
end
def brun1(x, handler)
  handler.is_a?(Proc) ? x.em_run(&handler) : run1(x, handler)
end
def brun2(x, handler)
  handler.is_a?(Proc) ? x.em_run($c, &handler) : run2(x, handler)
end
def brun3(x, handler)
  handler.is_a?(Proc) ? x.em_run($c, {durability: 'soft'}, &handler) : run3(x, handler)
end
def brun4(x, handler)
  handler.is_a?(Proc) ? x.em_run({durability: 'soft'}, &handler) : run4(x, handler)
end
$runners = [method(:run1), method(:run2), method(:run3), method(:run4),
            method(:brun1), method(:brun2), method(:brun3), method(:brun4)]
$runners = [method(:run3)]

r.table_create('test').run rescue nil
r.table('test').delete.run
r.table('test').insert({id: 0}).run
EM.threadpool_size = 1000
EM.run {
  $lambda_state = []
  $lambda = lambda {|err, row| $lambda_state << [err, row]}
  $handlers = [DefaultHandler.new, ValTypeHandler.new, ValTypeHandler2.new,
               ChangeOnlyHandler.new, ChangeHandler.new, CleverChangeHandler.new]
  $runners.each {|runner|
    ($handlers + [$lambda]).each {|handler|
      runner.call(r.table('test').get(0), handler)
      runner.call(r.table('test').get_all(0).coerce_to('array'), handler)
      runner.call(r.table('test'), handler)
      runner.call(r.table('fake'), handler)
      runner.call(r.table('test').get(0).changes, handler)
      runner.call(r.table('test').changes, handler)
    }
  }
  EM.defer {
    sleep 1
    r.table('test').insert({id: 1}).run
    r.table('test').get(0).update({a: 1}).run
  }
  EM.defer(proc{sleep 2}, proc{EM.stop})
}

def canonicalize x
  case x
  when Array
    x.map{|y| canonicalize(y)}.sort{|a,b| a.to_json <=> b.to_json}
  when Hash
    canonicalize(x.to_a)
  when RuntimeError
    "error"
  else
    x
  end
end
$res = ($handlers.map{|x| [x.class, canonicalize(x.state)]} +
        [[:lambda, canonicalize($lambda_state)]])

$expected = [[DefaultHandler,
              [[:err, "error"],
               [:val, [["id", 0]]],
               [:val, [["id", 0]]],
               [:val, [["id", 0]]],
               [:val, [["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]]],
               [:val, [["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]]],
               [:val, [["new_val", [["id", 0]]]]],
               [:val, [["new_val", [["id", 1]]], ["old_val", nil]]]]],
             [ValTypeHandler,
              [[:atom, [["id", 0]]],
               [:err, "error"],
               [:stream_val, [["id", 0]]],
               [:stream_val, [["id", 0]]],
               [:stream_val,
                [["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]]],
               [:stream_val,
                [["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]]],
               [:stream_val, [["new_val", [["id", 0]]]]],
               [:stream_val, [["new_val", [["id", 1]]], ["old_val", nil]]]]],
             [ValTypeHandler2,
              [[:atom, [["id", 0]]],
               [:atom, [[["id", 0]]]],
               [:err, "error"],
               [:stream_val, [["id", 0]]],
               [:stream_val,
                [["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]]],
               [:stream_val,
                [["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]]],
               [:stream_val, [["new_val", [["id", 0]]]]],
               [:stream_val, [["new_val", [["id", 1]]], ["old_val", nil]]]]],
             [ChangeOnlyHandler,
              [[:change, [["a", 1], ["id", 0]], [["id", 0]]],
               [:change, [["a", 1], ["id", 0]], [["id", 0]]],
               [:change, [["id", 1]], nil],
               [:err, "error"]]],
             [ChangeHandler,
              [[:atom, [["id", 0]]],
               [:atom, [[["id", 0]]]],
               [:change, [["a", 1], ["id", 0]], [["id", 0]]],
               [:change, [["a", 1], ["id", 0]], [["id", 0]]],
               [:change, [["id", 1]], nil],
               [:err, "error"],
               [:stream_val, [["id", 0]]],
               [:stream_val, [["new_val", [["id", 0]]]]]]],
             [CleverChangeHandler,
              [[:atom, [["id", 0]]],
               [:atom, [[["id", 0]]]],
               [:change, [["a", 1], ["id", 0]], [["id", 0]]],
               [:change, [["a", 1], ["id", 0]], [["id", 0]]],
               [:change, [["id", 1]], nil],
               [:err, "error"],
               [:initial_val, [["id", 0]]],
               [:stream_val, [["id", 0]]]]],
             [:lambda,
              [["error", nil],
               [[["id", 0]], nil],
               [[["id", 0]], nil],
               [[["id", 0]], nil],
               [[["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]], nil],
               [[["new_val", [["a", 1], ["id", 0]]], ["old_val", [["id", 0]]]], nil],
               [[["new_val", [["id", 0]]]], nil],
               [[["new_val", [["id", 1]]], ["old_val", nil]], nil]]]]
$expected = $expected.map{|arr| [arr[0], arr[1].flat_map{|x| [x]*$runners.size}]}

if $res != $expected
  raise RuntimeError, "Unexpected output:\n" + $res.inspect
end