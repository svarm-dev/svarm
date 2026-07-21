defmodule SvarmWeb.ApprovalsController do
  use SvarmWeb, :controller

  alias Svarm.Approval

  def index(conn, _params) do
    render(conn, :index, pending: Approval.list_pending())
  end

  def approve(conn, %{"id" => id}) do
    case Approval.approve(id) do
      :ok ->
        conn
        |> put_flash(:info, "Approved #{id}")
        |> redirect(to: ~p"/approvals")

      {:error, reason} ->
        conn
        |> put_flash(:error, Approval.flash_error(reason))
        |> redirect(to: ~p"/approvals")
    end
  end

  def reject(conn, %{"id" => id}) do
    case Approval.reject(id) do
      :ok ->
        conn
        |> put_flash(:info, "Rejected #{id}")
        |> redirect(to: ~p"/approvals")

      {:error, reason} ->
        conn
        |> put_flash(:error, Approval.flash_error(reason))
        |> redirect(to: ~p"/approvals")
    end
  end
end
