defmodule ChangelogWeb.PersonController do
  use ChangelogWeb, :controller

  alias Changelog.{Cache, Mailer, NewsItem, Newsletters, Person, Podcast, Repo,
                   Subscription}
  alias ChangelogWeb.Email

  plug RequireGuest, "before joining" when action in [:join]

  def show(conn, params) do
    pinned =
      NewsItem
      |> NewsItem.published
      |> NewsItem.pinned
      |> NewsItem.newest_first
      |> NewsItem.preload_all
      |> Repo.all
      |> Enum.map(&NewsItem.load_object/1)

    page =
      NewsItem
      |> NewsItem.published
      |> NewsItem.unpinned
      |> NewsItem.newest_first
      |> NewsItem.preload_all
      |> Repo.paginate(Map.put(params, :page_size, 20))

    items =
      page.entries
      |> Enum.map(&NewsItem.load_object/1)

    podcasts =
      Podcast.active
      |> Podcast.ours
      |> Podcast.oldest_first
      |> Podcast.preload_hosts
      |> Repo.all
      |> Kernel.++([Podcast.master])

    render(conn, :show, pinned: pinned, items: items, page: page, podcasts: podcasts)
  end

  def subscribe(conn = %{method: "GET"}, _params) do
    active =
      Podcast.active
      |> Podcast.oldest_first
      |> Podcast.preload_hosts
      |> Repo.all
      |> Kernel.++([Podcast.master])

    render(conn, :subscribe, podcasts: active)
  end
  def subscribe(conn = %{method: "GET"}, %{"to" => to}) when is_binary(to) do
    podcast = Podcast.get_by_slug!(to)

    if Podcast.has_feed(podcast) do
      conn
      |> assign(:podcast, podcast)
      |> render(:subscribe_podcast)
    else
      redirect(conn, to: person_path(conn, :subscribe))
    end
  end
  def subscribe(conn = %{method: "GET"}, _params) do
    render(conn, :subscribe)
  end
  def subscribe(conn = %{method: "POST"}, %{"gotcha" => robo}) when byte_size(robo) > 0 do
    conn
    |> put_flash(:error, "Something smells fishy. 🤖")
    |> redirect(to: person_path(conn, :subscribe))
  end
  def subscribe(conn = %{method: "POST"}, params = %{"email" => email}) do
    subscribe_to = Map.get(params, "to", "weekly")

    cond do
      String.ends_with?(email, "qq.com") ->
        conn
        |> put_flash(:error, "qq.com emails temporarily not allowed due to abuse.")
        |> redirect(to: person_path(conn, :subscribe))
      person = Repo.get_by(Person, email: email) ->
        welcome_subscriber(conn, person, subscribe_to)
      true ->
        changeset =
          Person.with_fake_data()
          |> Person.insert_changeset(params)

        case Repo.insert(changeset) do
          {:ok, person} ->
            log_request(conn)
            welcome_subscriber(conn, person, subscribe_to)
          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Something went wrong. 😭")
            |> redirect(to: person_path(conn, :subscribe))
        end
    end
  end
  def subscribe(conn = %{method: "POST"}, _params), do: redirect(conn, to: person_path(conn, :subscribe))

  defp welcome_subscriber(conn, person, subscribe_to) do
    person = Person.refresh_auth_token(person)

    case Newsletters.get_by_slug(subscribe_to) do
      nil -> subscribe_to_podcast(person, subscribe_to)
      newsletter -> subscribe_to_newsletter(person, newsletter)
    end

    conn
    |> put_flash(:success, "Only one step left! Check your inbox for a confirmation email.")
    |> redirect(to: root_path(conn, :index))
  end

  defp subscribe_to_newsletter(person, newsletter) do
    Craisin.Subscriber.subscribe(newsletter.list_id, Person.sans_fake_data(person))
     person |> Email.subscriber_welcome(newsletter) |> Mailer.deliver_later()
  end

  defp subscribe_to_podcast(person, "master") do
    for podcast <- Cache.podcasts() do
      context = "you signed up for email notifications on changelog.com"
      Subscription.subscribe(person, podcast, context)
    end

    person |> Email.subscriber_welcome(Podcast.master()) |> Mailer.deliver_later()
  end
  defp subscribe_to_podcast(person, slug) do
    podcast = Podcast.get_by_slug!(slug)
    context = "you signed up for email notifications on changelog.com"
    Subscription.subscribe(person, podcast, context)
    person |> Email.subscriber_welcome(podcast) |> Mailer.deliver_later()
  end

  def join(conn = %{method: "GET"}, params) do
    person = %Person{
      name: Map.get(params, "name"),
      email: Map.get(params, "email"),
      handle: Map.get(params, "handle"),
      github_handle: Map.get(params, "github_handle"),
      twitter_handle: Map.get(params, "twitter_handle")}

    render(conn, :join, changeset: Person.insert_changeset(person), person: nil)
  end

  def join(conn = %{method: "POST"}, %{"person" => person_params, "gotcha" => robo}) when byte_size(robo) > 0 do
    changeset = Person.insert_changeset(%Person{}, person_params)

    conn
    |> put_flash(:error, "Something smells fishy. 🤖")
    |> render(:join, changeset: changeset, person: nil)
  end
  def join(conn = %{method: "POST"}, %{"person" => person_params = %{"email" => email}}) do
    cond do
      String.ends_with?(email, "qq.com") ->
        changeset = Person.insert_changeset(%Person{}, person_params)

        conn
        |> put_flash(:error, "qq.com emails temporarily not allowed due to abuse.")
        |> render(:join, changeset: changeset, person: nil)
      person = Repo.get_by(Person, email: email) ->
        welcome_community(conn, person)
      true ->
        changeset = Person.insert_changeset(%Person{}, person_params)

        case Repo.insert(changeset) do
          {:ok, person} ->
            Repo.update(Person.file_changeset(person, person_params))
            welcome_community(conn, person)
          {:error, changeset} ->
            conn
            |> put_flash(:error, "Something went wrong. 😭")
            |> render(:join, changeset: changeset, person: nil)
        end
    end
  end
  def join(conn = %{method: "POST"}, _params), do: redirect(conn, to: person_path(conn, :join))

  defp welcome_community(conn, person) do
    person = Person.refresh_auth_token(person)

    Email.community_welcome(person) |> Mailer.deliver_later()

    conn
    |> put_flash(:success, "Only one step left! Check your inbox for a confirmation email.")
    |> redirect(to: root_path(conn, :index))
  end
end
