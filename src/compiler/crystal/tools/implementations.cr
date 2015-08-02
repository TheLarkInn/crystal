require "../syntax/ast"
require "../compiler"
require "json"

module Crystal
  class Call
    def name_location
      loc = location.not_nil!
      Location.new(loc.line_number, name_column_number, loc.filename)
    end

    def name_end_location
      loc = location.not_nil!
      Location.new(loc.line_number, name_column_number + name_length, loc.filename)
    end
  end

  class ImplementationResult
    json_mapping({
      status:           {type: String},
      message:          {type: String},
      implementations:  {type: Array(ImplementationTrace), nilable: true},
    })

    def initialize(@status, @message)
    end
  end

  # Contains information regarding where an implementation is defined.
  # It keeps track of macro expansion in a human friendly way and
  # pointing to the exact line an expansion and method definition occurs.
  class ImplementationTrace
    json_mapping({
      line:     {type: Int32},
      column:   {type: Int32},
      filename: {type: String},
      macro:    {type: String, nilable: true},
      expands:  {type: ImplementationTrace, nilable: true},
    })

    def initialize(loc : Location)
      f = loc.filename
      if f.is_a?(String)
        self.line = loc.line_number
        self.column = loc.column_number
        self.filename = f
      elsif f.is_a?(VirtualFile)
        macro_location = f.macro.location.not_nil!
        self.macro = f.macro.name
        self.filename = macro_location.filename.to_s
        self.line = macro_location.line_number + loc.line_number
        self.column = loc.column_number
      else
        raise "not implemented"
      end
    end

    def self.parent(loc : Location)
      f = loc.filename

      if f.is_a?(VirtualFile)
        f.expanded_location
      else
        nil
      end
    end

    def self.build(loc : Location)
      res = self.new(loc)
      parent = self.parent(loc)

      while parent
        outer = self.new(parent)
        parent = self.parent(parent)

        outer.expands = res
        res = outer
      end

      res
    end
  end

  class ImplementationsVisitor < Visitor
    getter locations

    def initialize(@target_location)
      @locations = [] of Location
    end

    def process(result : Compiler::Result)
      result.program.def_instances.each_value do |typed_def|
        typed_def.accept(self)
      end

      result.node.accept(self)

      if @locations.empty?
        return ImplementationResult.new("failed", "no implementations or method call found")
      else
        res = ImplementationResult.new("ok", "#{@locations.count} implementation#{@locations.count > 1 ? "s" : ""} found")
        res.implementations = @locations.map { |loc| ImplementationTrace.build(loc) }
        return res
      end
    end

    def visit(node : Call)
      if node.location
        if @target_location.between?(node.name_location, node.name_end_location)

          if target_defs = node.target_defs
            target_defs.each do |target_def|
              @locations << target_def.location.not_nil!
            end
          end

        else
          contains_target(node)
        end
      end
    end

    def visit(node)
      contains_target(node)
    end

    private def contains_target(node)
      if loc_start = node.location
        loc_end = node.end_location.not_nil!
        @target_location.between?(loc_start, loc_end)
      else
        # if node has no location, assume they may contain the target.
        # for example with the main expressions ast node this matters
        true
      end
    end
  end
end