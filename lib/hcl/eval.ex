defmodule HCL.Eval do
  @moduledoc """
  Evaluates the HCL AST into either a partially applied structure or materialized structure

  ## Examples

  With assignement:

    %HCL.Ast.Body{} = body = HCL.from_binary("a = 1")
    %{"a" => 1} = HCL.Eval.eval(body)


  Expressions:

    %HCL.Ast.Body{} = body = HCL.from_binary("a = 1 + 1 + (4 * 2)")
    %{"a" => 10} = HCL.Eval.eval(body)

  Functions:

     hcl = "a = trim("    a ")"
     %HCL.Ast.Body{} = body = HCL.from_binary(hcl)
     %{"a" => "a"} = HCL.Eval.eval(body, functions: %{"trim" => &String.trim/1})
  """

  alias HCL.Ast.{
    AccessOperation,
    Attr,
    Binary,
    Block,
    Body,
    Comment,
    ForExpr,
    FunctionCall,
    Identifier,
    Literal,
    Object,
    TemplateExpr,
    Tuple,
    Unary
  }

  defstruct [:functions, ctx: %{}, symbol_table: %{}]

  @type t :: %__MODULE__{ctx: Map.t()}

  @doc """
  Evaluates the Ast by walking the tree recursivly. Each node will be evaluated
  """
  @spec eval(term(), Keyword.t()) :: {:ok, term()} | {:error, term()}
  def eval(hcl, opts \\ []) do
    functions = Keyword.get(opts, :functions, %{})
    symbol_table = Keyword.get(opts, :variables, %{})

    do_eval(hcl, %__MODULE__{functions: functions, symbol_table: symbol_table})
  end

  defp do_eval(%Body{statements: stmts}, ctx) do
    Enum.reduce(stmts, ctx, fn x, acc ->
      case do_eval(x, acc) do
        {{k, v}, acc} ->
          %{acc | ctx: Map.put(acc.ctx, k, v)}

        {map, acc} when is_map(map) ->
          %{acc | ctx: Map.merge(acc.ctx, map)}

        {:ignore, acc} ->
          acc
      end
    end)
  end

  defp do_eval(%Block{body: body, type: type, labels: labels}, ctx) do
    # Build a nested structure from type + labels.
    # Given the a block:
    # a "b" "c" {
    #   d = 1
    # }
    # The following structure should be created:
    #
    # {
    #   "a" => %{
    #     "b" => %{
    #       "d" => 1
    #     }
    #   }
    # }
    block_scope =
      [type | labels]
      |> scope([])
      |> Enum.reverse()

    block_ctx =
      do_eval(body, %__MODULE__{symbol_table: ctx.symbol_table, functions: ctx.functions})

    {put_in(ctx.ctx, block_scope, block_ctx.ctx), ctx}
  end

  defp do_eval(%Attr{name: name, expr: expr}, ctx) do
    {value, ctx} = do_eval(expr, ctx)

    st = Map.put(ctx.symbol_table, name, value)
    {{name, value}, %{ctx | symbol_table: st}}
  end

  defp do_eval(%Comment{}, ctx) do
    {:ignore, ctx}
  end

  defp do_eval(%Unary{expr: expr, operator: op}, ctx) do
    {value, ctx} = do_eval(expr, ctx)

    {apply(Kernel, op, [value]), ctx}
  end

  defp do_eval(%Binary{left: left, operator: op, right: right}, ctx) do
    {left_value, ctx} = do_eval(left, ctx)
    {right_value, ctx} = do_eval(right, ctx)

    {apply(Kernel, op, [left_value, right_value]), ctx}
  end

  defp do_eval(%Literal{value: value}, ctx) do
    {ast_value_to_value(value), ctx}
  end

  defp do_eval(%Identifier{name: name}, ctx) do
    id_value = Map.fetch!(ctx.symbol_table, name)
    {id_value, ctx}
  end

  defp do_eval(%TemplateExpr{delimiter: nil, lines: lines}, ctx) do
    {Enum.join(lines, "\n"), ctx}
  end

  defp do_eval(%Tuple{values: values}, ctx) do
    {values, ctx} =
      Enum.reduce(values, {[], ctx}, fn value, {list, ctx} ->
        {value, ctx} = do_eval(value, ctx)
        {[value | list], ctx}
      end)

    {Enum.reverse(values), ctx}
  end

  defp do_eval(%Object{kvs: kvs}, ctx) do
    Enum.reduce(kvs, {%{}, ctx}, fn {k, v}, {state, ctx} ->
      {value, ctx} = do_eval(v, ctx)
      state = Map.put(state, k, value)
      {state, ctx}
    end)
  end

  defp do_eval(%FunctionCall{name: name, arity: arity, args: args}, %{functions: funcs} = ctx) do
    case Map.get(funcs, name) do
      nil ->
        raise ArgumentError,
          message:
            "FunctionCalls cannot be used without providing a function with the same arity in #{__MODULE__}.eval/2. Got: #{name}/#{arity}"

      func when not is_function(func, arity) ->
        raise ArgumentError,
          message:
            "FunctionCall arity missmatch Expected: #{name}/#{arity} got: arity=#{:erlang.fun_info(func)[:arity]}"

      func ->
        {args, ctx} =
          Enum.reduce(args, {[], ctx}, fn arg, {acc, ctx} ->
            {eval_arg, ctx} = do_eval(arg, ctx)
            {[eval_arg | acc], ctx}
          end)

        {Kernel.apply(func, Enum.reverse(args)), ctx}
    end
  end

  defp do_eval(
         %ForExpr{
           enumerable: enum,
           conditional: conditional,
           enumerable_type: e_t,
           keys: keys,
           body: body
         },
         ctx
       ) do
    {enum, ctx} = do_eval(enum, ctx)
    {acc, reducer} = closure(keys, conditional, body, ctx)

    for_into =
      case e_t do
        :for_tuple -> &Function.identity/1
        :for_object -> &Enum.into(&1, %{})
      end

    iterated =
      enum
      |> Enum.reduce(acc, reducer)
      |> elem(0)
      |> Enum.reverse()
      |> for_into.()

    {iterated, ctx}
  end

  defp do_eval(%AccessOperation{expr: expr, operation: op}, ctx) do
    {expr_value, ctx} = do_eval(expr, ctx)
    {access_fn, ctx} = eval_op(op, ctx)

    {Kernel.get_in(expr_value, access_fn), ctx}
  end

  defp do_eval({k, v}, ctx) do
    {k_value, ctx} = do_eval(k, ctx)
    {v_value, ctx} = do_eval(v, ctx)

    {{k_value, v_value}, ctx}
  end

  defp eval_op({:index_access, index_expr}, ctx) do
    {index, ctx} = do_eval(index_expr, ctx)

    {[Access.at(index)], ctx}
  end

  defp eval_op({:attr_access, attrs}, ctx) do
    accs = for attr <- attrs, do: Access.key!(attr)

    {accs, ctx}
  end

  defp eval_op({:attr_splat, access_op}, ctx) do
    {accs, ctx} = eval_op(access_op, ctx)
    func = access_map(accs)

    {[func], ctx}
  end

  defp eval_op({:full_splat, access_ops}, ctx) do
    {accs, ctx} =
      Enum.reduce(access_ops, {[], ctx}, fn op, {acc, ctx} ->
        {op, ctx} = eval_op(op, ctx)

        {List.flatten([op | acc]), ctx}
      end)

    func =
      accs
      |> Enum.reverse()
      |> access_map()
      |> List.wrap()

    {func, ctx}
  end

  defp access_map(ops) do
    fn :get, data, next when is_list(data) ->
      data |> Enum.map(&get_in(&1, ops)) |> Enum.map(next)
    end
  end

  defp ast_value_to_value({:int, int}) do
    int
  end

  def scope([key], acc) do
    [key | acc]
  end

  def scope([key | rest], acc) do
    acc = [Access.key(key, %{}) | acc]
    scope(rest, acc)
  end

  defp closure([key], conditional, body, ctx) do
    conditional_fn = closure_cond(conditional)

    reducer = fn v, {acc, ctx} ->
      ctx = %{ctx | symbol_table: Map.put(ctx.symbol_table, key, v)}

      acc =
        if conditional_fn.(ctx) do
          {value, _} = do_eval(body, ctx)
          [value | acc]
        else
          acc
        end

      {acc, ctx}
    end

    {{[], ctx}, reducer}
  end

  defp closure([index, value], conditional, body, ctx) do
    conditional_fn = closure_cond(conditional)

    reducer = fn v, {acc, i, ctx} ->
      st =
        ctx.symbol_table
        |> Map.put(index, i)
        |> Map.put(value, v)

      ctx = %{ctx | symbol_table: st}

      acc =
        if conditional_fn.(ctx) do
          {value, _} = do_eval(body, ctx)
          [value | acc]
        else
          acc
        end

      {acc, i + 1, ctx}
    end

    {{[], 0, ctx}, reducer}
  end

  defp closure_cond(nil), do: fn _ctx -> true end

  defp closure_cond(expr) do
    fn ctx ->
      expr
      |> do_eval(ctx)
      |> elem(0)
    end
  end
end
