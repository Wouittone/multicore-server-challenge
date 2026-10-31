primitive SQL
  fun user_fields(): String =>
    "id, username, email, bio, image"

  fun slug(title: String): String =>
    "trim(both '-' from lower(regexp_replace(" + title +
      ", '[^A-Za-z0-9]+', '-', 'g')))"

  fun profile(following: String): String =>
    "u.username, u.bio, u.image, " + following + " AS following"

  fun follows(): String =>
    "EXISTS (SELECT 1 FROM follows fo " +
      "WHERE fo.follower_id = $1 AND fo.followee_id = u.id)"

  fun article(full: Bool = true): String =>
    "SELECT a.id, a.slug, a.title, a.description, " +
      (if full then "a.body, " else "NULL::text AS body, " end) +
      "a.created_at, a.updated_at, " +
      "ARRAY(SELECT t.name FROM article_tags at " +
      "JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id " +
      "ORDER BY t.name) AS tag_list, " +
      "(SELECT count(*) FROM favorites f " +
      "WHERE f.article_id = a.id) AS favorites_count, " +
      "EXISTS (SELECT 1 FROM favorites f " +
      "WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, " +
      profile(follows()) +
      " FROM articles a JOIN users u ON u.id = a.author_id "

  fun comment(following: String): String =>
    "SELECT c.id, c.body, c.created_at, c.updated_at, " +
      profile(following) + " "

  fun page(filter: String): String =>
    let select' = article(false)
    match filter
    | "tag" =>
      select' + "WHERE a.id IN (SELECT at.article_id FROM article_tags at " +
        "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " +
        "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
    | "author" =>
      select' +
        "WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) " +
        "ORDER BY a.id DESC LIMIT $2 OFFSET $3"
    | "favorited" =>
      select' + "WHERE a.id IN (SELECT f.article_id FROM favorites f " +
        "WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = $4) " +
        "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
    | "feed" =>
      select' + "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL " +
        "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " +
        "ORDER BY a2.id DESC LIMIT " +
        "(LEAST($2::numeric + $3::numeric, 9223372036854775807)::bigint)) x " +
        "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) " +
        "ORDER BY a.id DESC"
    else
      select' + "ORDER BY a.id DESC LIMIT $2 OFFSET $3"
    end

  fun count(filter: String): String =>
    let inner =
      match filter
      | "tag" =>
        "SELECT 1 FROM article_tags at WHERE at.tag_id = " +
          "(SELECT t.id FROM tags t WHERE t.name = $1)"
      | "author" =>
        "SELECT 1 FROM articles a WHERE a.author_id = " +
          "(SELECT u.id FROM users u WHERE u.username = $1)"
      | "favorited" =>
        "SELECT 1 FROM favorites f WHERE f.user_id = " +
          "(SELECT u.id FROM users u WHERE u.username = $1)"
      | "feed" =>
        "SELECT 1 FROM articles a WHERE a.author_id IN " +
          "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)"
      else "SELECT 1 FROM articles"
      end
    "SELECT count(*) FROM (" + inner + " LIMIT 1000) s"
