defmodule HeexFormatter.Formatter do
  @moduledoc false

  # Use 2 spaces for a tab
  @tab "  "

  # Line length of opening tags before splitting attributes onto their own line
  @default_line_length 98

  # The formatter will ignore contents within this tag. Therefore, it will not
  # be formatted.
  @special_modes ~w(script style code pre comment)a

  # List void tags to be handled on `tag_open`.
  @void_tags ~w(area base br col hr img input link meta param command keygen source)

  @doc """
  Format the given tokens according to the given options.

  ### Options

  It take all options at `.formatter.exs` as it does for Mix format since it uses
  these options to format Elixir code.

  https://hexdocs.pm/mix/main/Mix.Tasks.Format.html#module-formatting-options

  In addition, these options are taken:

  `heex_line_length`: maximum line length for heex templates. In case it is not
  the provided, it tries to use `line_length` or `@default_line_length`.

  ### Examples

    iex> tokens = [
    ...>   {:tag_open, "section", [], %{column: 1, line: 1}},
    ...>   {:tag_open, "div", [], %{column: 1, line: 2}},
    ...>   {:tag_open, "h1", [], %{column: 1, line: 3}},
    ...>   {:text, "Hello", %{column_end: 10, line_end: 3}},
    ...>   {:tag_close, "h1", %{column: 10, line: 3}},
    ...>   {:tag_close, "div", %{column: 1, line: 4}},
    ...>   {:tag_close, "section", %{column: 1, line: 5}}
    ...> ]
    iex> HeexFormatter.Formatter.format(tokens, [])
    "<section>\n  <div>\n    <h1>\n      Hello\n    </h1>\n  </div>\n</section>\n"

  """
  def format(tokens, opts) do
    initial_state = %{
      buffer: [],
      previous_token: nil,
      indentation: 0,
      line_length: opts[:heex_line_length] || opts[:line_length] || @default_line_length,
      formatter_opts: opts,
      mode: :normal,
      # Set the eex block. We use it to identify case and cond statements so that
      # we can indent them correctly.
      eex_block: nil
    }

    tokens
    |> Enum.reduce(initial_state, fn token, state ->
      token
      |> token_to_string(state)
      |> put_previous_token(token)
    end)
    |> buffer_to_string()
  end

  # Unless it is a line break or empty line, we want put the previous token
  # so we can compare with the current one.
  defp put_previous_token(state, {:text, text, _met} = token) do
    if line_break_or_empty_space?(text) do
      state
    else
      %{state | previous_token: token}
    end
  end

  defp put_previous_token(state, token), do: %{state | previous_token: token}

  defp buffer_to_string(state) do
    state.buffer
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> then(&(&1 <> "\n"))
  end

  defp token_to_string({:tag_open, name, attrs, meta} = token, state) do
    self_close? = Map.get(meta, :self_close, false)
    indent = indent_expression(state.indentation)
    line_break = may_add_line_break(state.previous_token)

    attrs =
      if put_attrs_in_separeted_lines?(token, state.line_length) do
        {:new_line, render_tag_attributes(:new_line, attrs, state.indentation)}
      else
        {:current_line, render_tag_attributes(:current_line, attrs)}
      end

    tag_opened =
      case attrs do
        {:new_line, attrs} ->
          suffix = if self_close?, do: "/>", else: ">"
          "#{indent}<#{name}\n#{attrs}\n#{indent}#{suffix}"

        {:current_line, attrs} ->
          suffix = if self_close?, do: " />", else: ">"
          "#{indent}<#{name}#{attrs}#{suffix}"
      end

    indentation =
      if self_close? || name in @void_tags do
        state.indentation
      else
        state.indentation + 1
      end

    %{
      state
      | buffer: [line_break <> tag_opened | state.buffer],
        indentation: indentation,
        mode: mode(name)
    }
  end

  # Handle HTMl comments when the given token contains `context.` Here, we don't
  # format the text, we just ensure one `\n` at the end and set the mode as `:comment`.
  defp token_to_string({:text, text, %{context: context}}, state) when is_list(context) do
    mode = if :comment_start in context, do: :comment, else: :normal

    text =
      if String.contains?(text, "-->\n") do
        String.trim_trailing(text) <> "\n"
      else
        text
      end

    %{state | buffer: [text | state.buffer], mode: mode}
  end

  # Handle text, eex_tag and eex_tag_render when mode is one of the `@special_modes`.
  # Here we don't want to format anything but just return the text as it is.
  defp token_to_string({tag, text, _meta}, %{mode: mode} = state)
       when tag in ~w(text eex_tag eex_tag_render)a and mode in @special_modes do
    %{state | buffer: [String.trim_trailing(text) | state.buffer]}
  end

  defp token_to_string({:text, text, _meta}, state) do
    text =
      if line_break_or_empty_space?(text) do
        handle_line_break(text)
      else
        handle_text(text, state)
      end

    %{state | buffer: [text | state.buffer]}
  end

  # Handle tag_close when mode is one of the special modes. Here, we want to
  # close the tag in the next line with the current indentation - 1.
  defp token_to_string({:tag_close, tag, _meta}, %{mode: mode} = state)
       when mode in @special_modes do
    indentation = state.indentation - 1
    tag_closed = indent_expression("</#{tag}>", indentation)
    %{state | buffer: [tag_closed | state.buffer], indentation: indentation, mode: :normal}
  end

  defp token_to_string({:tag_close, tag, _meta}, state) do
    indentation = state.indentation - 1

    tag_closed =
      case state.previous_token do
        # Do not add a line break when the previous tag is a comment. In case
        # the metadata contains context, it is a comment.
        {:text, _text, %{context: context}} when is_list(context) ->
          "</#{tag}>"

        {:text, _text, _meta} ->
          if tag_open_with_line_break?(state.buffer, tag) do
            indent_expression("</#{tag}>", indentation)
          else
            "</#{tag}>"
          end

        # In case the previous token is a tag_open and it is the same tag, we
        # don't want to break lines since this tag has not content at all.
        {:tag_open, ^tag, _attrs, _meta} ->
          "</#{tag}>"

        _token ->
          indent_expression("</#{tag}>", indentation)
      end

    %{state | buffer: [tag_closed | state.buffer], indentation: indentation, mode: mode(tag)}
  end

  defp token_to_string({:eex_tag_render, tag, meta}, state) do
    indentation = if meta.block?, do: state.indentation + 1, else: state.indentation
    formatted_tag = format_eex(tag, state)

    case state.previous_token do
      nil ->
        %{state | buffer: [formatted_tag | state.buffer], indentation: indentation}

      {:text, text, _meta} ->
        eex_tag =
          if html_comment?(text) do
            indent_expression(formatted_tag, state.indentation)
          else
            " " <> formatted_tag
          end

        %{state | buffer: [eex_tag | state.buffer], indentation: indentation}

      _token ->
        eex_tag = indent_expression(formatted_tag, state.indentation)
        %{state | buffer: [eex_tag | state.buffer], indentation: indentation}
    end
  end

  # eex_tag represents <% %>
  defp token_to_string({:eex_tag, "<% else %>" = tag, _meta}, state) do
    eex_tag = indent_expression(tag, state.indentation - 1)

    %{state | buffer: [eex_tag | state.buffer]}
  end

  defp token_to_string({:eex_tag, "<% end %>" = tag, _meta}, state) do
    indentation =
      if state.eex_block in ~w(case cond)a do
        state.indentation - 2
      else
        state.indentation - 1
      end

    eex_tag = indent_expression(tag, indentation)

    %{state | buffer: [eex_tag | state.buffer], indentation: indentation, eex_block: nil}
  end

  # Handle eex_tag such as <% {:ok, result} -> %> present within case statements
  # or cond.
  defp token_to_string({:eex_tag, tag, %{block?: true}}, state) do
    case state.previous_token do
      {:eex_tag_render, eex_tag_render, %{block?: true}} ->
        eex_block = extract_eex_block_name(eex_tag_render)
        eex_tag = indent_expression(tag, state.indentation)

        %{
          state
          | buffer: [eex_tag | state.buffer],
            indentation: state.indentation + 1,
            eex_block: eex_block
        }

      _token ->
        eex_tag = indent_expression(tag, state.indentation - 1)
        %{state | buffer: [eex_tag | state.buffer]}
    end
  end

  defp token_to_string({:eex_tag, tag, _meta}, state) do
    case state.previous_token do
      nil ->
        %{state | buffer: [tag | state.buffer]}

      {type, _tag, _meta} when type in [:eex_tag_render, :eex_tag] ->
        eex_tag = indent_expression(tag, state.indentation)

        %{state | buffer: [eex_tag | state.buffer]}

      _token ->
        indentation = state.indentation - 1
        eex_tag = indent_expression(tag, indentation)

        %{state | buffer: [eex_tag | state.buffer], indentation: indentation}
    end
  end

  # Helper for indenting the given expression according to the given indentation.
  #
  # Examples
  #
  #    iex> indent_expression("<%= @user.name %>", 1)
  #    "\n  <%= @user.name %>"
  defp indent_expression(expression, indentation) do
    "\n" <> indent_expression(indentation) <> expression
  end

  # Helper for duplicating `@tab` so it can be used as indentation.
  #
  # Examples
  #
  #    iex> indent_expression(2)
  #    "  "
  defp indent_expression(indentation) do
    String.duplicate(@tab, max(0, indentation))
  end

  defp put_attrs_in_separeted_lines?({:tag_open, tag, attrs, meta}, max_line_length) do
    self_closed? = Map.get(meta, :self_close, false)

    # Calculate attrs length. It considers 1 space between each attribute, that
    # is why it adds + 1 for each attribute.
    attrs_length =
      attrs
      |> Enum.map(fn attr ->
        attr
        |> render_attribute()
        |> String.length()
        |> then(&(&1 + 1))
      end)
      |> Enum.sum()

    # Calculate the length of tag + attrs + spaces.
    length_on_same_line = attrs_length + String.length(tag) + if self_closed?, do: 4, else: 2

    if length(attrs) > 1 do
      length_on_same_line > max_line_length
    else
      false
    end
  end

  # Render tag attributes according to the given arguments.
  #
  # `:new_line`: it join `\n` for each attribute so that they will be rendered
  #  in the next line. It also adds indentation + 1.
  #
  # `:current_line`: it will render each attribute separated by " ". Returns ""
  #  in case there is no attrs to be rendered.
  defp render_tag_attributes(:new_line, attrs, indentation) do
    indent = indent_expression(indentation + 1)
    Enum.map_join(attrs, "\n", &"#{indent}#{render_attribute(&1)}")
  end

  defp render_tag_attributes(:current_line, attrs) do
    attrs
    |> Enum.map(&render_attribute/1)
    |> Enum.intersperse(" ")
    |> Enum.join("")
    |> then(&if &1 != "", do: " #{&1}")
  end

  defp render_attribute(attr) do
    case attr do
      {:root, {:expr, expr, _}} ->
        ~s({#{expr}})

      {attr, {:string, value, _meta}} ->
        ~s(#{attr}="#{value}")

      {attr, {:expr, value, _meta}} ->
        ~s(#{attr}={#{value}})

      {attr, {_, value, _meta}} ->
        ~s(#{attr}=#{value})

      {attr, nil} ->
        ~s(#{attr})
    end
  end

  # Check if the given tag contains line breaks in the given html state.
  #
  # Useful to know if we should either close the tag in the current line or
  # in the next line. For instance:
  #
  #   should close the tag in the current line.
  #   <p>My title
  #
  #   should close the tag in the next line.
  #   <p class="some-class">  \nShould break line
  defp tag_open_with_line_break?(buffer, tag) do
    buffer
    |> current_tag_open([], tag)
    |> String.contains?("\n")
  end

  defp current_tag_open([head | rest], buffer, tag) do
    if String.contains?(head, "<#{tag}>") do
      current_tag_open([], buffer, tag)
    else
      current_tag_open(rest, [head | buffer], tag)
    end
  end

  defp current_tag_open([], buffer, _tag), do: IO.iodata_to_binary(buffer)

  # Returns an empty space or a "\n".
  #
  # At the moment this is only used for tag_open. The general rule is that it
  # should break line. The exception # is when there is no previous_token or the
  # previous_token is a HTML comment.
  defp may_add_line_break(nil), do: ""

  defp may_add_line_break({:text, _text, %{context: context}})
       when is_list(context),
       do: ""

  defp may_add_line_break({:text, text, _meta}) do
    if html_comment?(text), do: "", else: "\n"
  end

  defp may_add_line_break(_token), do: "\n"

  defp html_comment?(text),
    do: String.contains?(text, "<!--") and String.contains?(text, "-->")

  # Returns `script`, `style`, `code` or `pre` when the given tag is one of these
  # tags. Otherwise, it returns `normal`.
  defp mode(tag) when tag in ~w(script style code pre), do: String.to_existing_atom(tag)
  defp mode(_tag), do: :normal

  # Returns how given text formatted according to the current state.
  defp handle_text(text, %{previous_token: {:eex_tag_render, _tag, %{block?: true}}} = state) do
    indent = indent_expression(state.indentation)
    "\n" <> indent <> String.trim(text)
  end

  defp handle_text(text, %{previous_token: {:eex_tag_render, _tag, _meta}}) do
    " " <> String.trim(text)
  end

  # In case the previous token is a tag open, this will check if the text
  # should either go to the current line or next line. Tag with attributes
  # always go to the next line.
  defp handle_text(text, %{previous_token: {:tag_open, _tag, attrs, _meta}} = state) do
    text = String.trim(text)

    if String.length(text) < state.line_length and Enum.empty?(attrs) do
      text
    else
      indent = indent_expression(state.indentation)
      "\n" <> indent <> text
    end
  end

  defp handle_text(text, state) do
    cond do
      html_comment?(text) ->
        String.trim_trailing(text)

      String.contains?(text, "<!DOCTYPE html>") ->
        String.trim(text)

      true ->
        indent = indent_expression(state.indentation)
        "\n" <> indent <> String.trim(text)
    end
  end

  # Returns either a line break or empty string. In case there is more than one
  # line break, it means that we should keep one line break.
  defp handle_line_break(text) do
    line_breaks_count = text |> String.graphemes() |> Enum.count(&(&1 == "\n"))

    if line_breaks_count > 1, do: "\n", else: ""
  end

  defp line_break_or_empty_space?(text), do: String.trim(text) == ""

  # Extracts the block name of the given eex tag render.
  #
  # Examples
  #
  #   iex> extract_eex_block_name("<%= case {:ok, "Hello"} %>")
  #   :case
  #
  #   iex> extract_eex_block_name("<%= cond do %>")
  #   :cond
  defp extract_eex_block_name("<%= " <> rest) do
    [keyword | _rest] = String.split(rest)
    String.to_existing_atom(keyword)
  end

  # Format a given eex code to match provided indentation in HEEx template.
  #
  # Given the following code:
  #
  # "form_for @changeset, Routes.user_path(@conn, :create), [class: "w-full", phx_change: "on_change"], fn f ->"
  #
  # The following string will be returned:
  #
  # <%= form_for @changeset,
  #            Routes.user_path(@conn, :create),
  #            [class: \"w-full\", phx_change: \"on_change\"],
  #            fn f -> %>
  defp format_eex(code, state) do
    code = String.replace(code, ["<%= ", " %>"], "")

    formatted_code =
      cond do
        code =~ ~r/\sdo\z/m ->
          format_ends_with_do(code, state.formatter_opts)

        String.ends_with?(code, "->") ->
          format_ends_with_priv_fn(code, state.formatter_opts)

        true ->
          run_formatter(code, state.formatter_opts)
      end
      |> String.split("\n")
      |> Enum.join("\n" <> String.duplicate(@tab, state.indentation))

    "<%= #{formatted_code} %>"
  end

  defp format_ends_with_do(code, formatter_opts) do
    (code <> "\nend")
    |> run_formatter(formatter_opts)
    |> String.replace_trailing("\nend", "")
  end

  defp format_ends_with_priv_fn(code, formatter_opts) do
    (code <> "\nnil\nend")
    |> run_formatter(formatter_opts)
    |> String.trim()
    |> remove_added_code()
    |> String.split("\n")
    |> Enum.slice(0..-3)
    |> Enum.join("\n")
  end

  defp remove_added_code(code) do
    if String.ends_with?(code, ")") do
      fn_name_length = String.split(code, "(") |> Enum.at(0) |> String.length()
      extra_space = String.duplicate(" ", fn_name_length + 1)

      code
      |> String.replace("(\n ", "", global: false)
      |> String.replace("\n  ", "\n" <> extra_space)
      |> String.replace_trailing("\n)", "")
    else
      code
    end
  end

  defp run_formatter(code, opts) do
    code
    |> Code.format_string!(opts)
    |> IO.iodata_to_binary()
  end
end
