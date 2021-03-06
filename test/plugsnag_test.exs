defmodule PlugsnagTest do
  use ExUnit.Case
  use Plug.Test

  defmodule TestException do
    defexception plug_status: 403, message: "oops"
  end

  defmodule ErrorRaisingPlug do
    defmacro __using__(_env) do
      quote do
        def call(conn, _opts) do
          raise Plug.Conn.WrapperError, conn: conn,
          kind: :error, stack: System.stacktrace,
          reason: TestException.exception([])
        end
      end
    end
  end

  defmodule TestPlug do
    use Plugsnag
    use ErrorRaisingPlug
  end

  defmodule FakePlugsnag do
    def report(exception, options \\ []) do
      send self(), {:report, {exception, options}}
    end
  end

  setup do
    Application.put_env(:plugsnag, :reporter, FakePlugsnag)
  end

  test "Raising an error on failure" do
    conn = conn(:get, "/")

    assert_raise TestException, "oops", fn ->
      TestPlug.call(conn, [])
    end

    assert_received {:report, {%TestException{}, _}}
  end

  test "includes connection metadata in the report" do
    conn = conn(:get, "/?hello=computer")

    catch_error TestPlug.call(conn, [])
    assert_received {:report, {%TestException{}, options}}
    metadata = Keyword.get(options, :metadata)

    assert get_in(metadata, [:request,:query_string]) == "hello=computer"
  end

  test "allows modifying bugsnag report options before it's sent" do
    defmodule TestErrorReportBuilder do
      @behaviour Plugsnag.ErrorReportBuilder

      def build_error_report(error_report, conn) do
        user_info =  %{
          id: conn |> get_req_header("x-user-id") |> List.first
        }

        %{error_report | user: user_info}
      end
    end

    defmodule TestPlugsnagCallbackPlug do
      use Plugsnag, error_report_builder: TestErrorReportBuilder
      use ErrorRaisingPlug
    end

    conn = conn(:get, "/")

    conn =
      conn
      |> put_req_header("x-user-id", "abc123")

    catch_error TestPlugsnagCallbackPlug.call(conn, [])
    assert_received {:report, {%TestException{}, options}}

    assert Keyword.get(options, :user) == %{
     id: "abc123"
    }
  end

  test "allows modifying bugsnag report options before it's sent and include exception" do
    defmodule TestErrorReportBuilderOverride do
      @behaviour Plugsnag.ErrorReportBuilder

      def build_error_report(error_report, conn, exception, _stack) do
        user_info =  %{
          id: conn |> get_req_header("x-user-id") |> List.first
        }

        error_report
        |> Map.put(:user, user_info)
        |> Map.put(:custom_grouping_hash, to_string(exception.__struct__))
      end
    end

    defmodule TestPlugsnagCallbackPlugOverride do
      use Plugsnag, error_report_builder: TestErrorReportBuilderOverride
      use ErrorRaisingPlug

      defp build_options(error_report_builder, conn, exception, stack) do
        %Plugsnag.ErrorReport{}
        |> error_report_builder.build_error_report(conn, exception, stack)
        |> Map.delete(:__struct__)
        |> Keyword.new
      end
    end

    conn =
      conn(:get, "/")
      |> put_req_header("x-user-id", "abc123")

    catch_error TestPlugsnagCallbackPlugOverride.call(conn, [])
    assert_received {:report, {%TestException{}, options}}

    exception_struct = Keyword.get(options, :custom_grouping_hash)
    assert exception_struct == to_string(PlugsnagTest.TestException)

    assert Keyword.get(options, :user) == %{
     id: "abc123"
    }
  end

end
