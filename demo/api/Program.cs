using Npgsql;

var passwordPath = Environment.GetEnvironmentVariable("DB_PASSWORD_FILE")
    ?? throw new InvalidOperationException("DB_PASSWORD_FILE is required.");
var password = (await File.ReadAllTextAsync(passwordPath)).TrimEnd();
var connectionString = new NpgsqlConnectionStringBuilder
{
    Host = Environment.GetEnvironmentVariable("DB_HOST") ?? "database",
    Database = Environment.GetEnvironmentVariable("DB_NAME") ?? "platform",
    Username = Environment.GetEnvironmentVariable("DB_USER") ?? "platform",
    Password = password,
    Timeout = 3,
    CommandTimeout = 5
}.ConnectionString;
var dataSource = NpgsqlDataSource.Create(connectionString);

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(dataSource);
var app = builder.Build();

app.MapGet("/health/live", () => Results.Ok(new { status = "live" }));

app.MapGet("/health/ready", async (NpgsqlDataSource database) =>
{
    try
    {
        await using var connection = await database.OpenConnectionAsync();
        await using var command = new NpgsqlCommand(
            "SELECT to_regclass('public.notes') IS NOT NULL",
            connection);
        if (!(bool)(await command.ExecuteScalarAsync())!)
            return Results.Problem("Database schema is unavailable.", statusCode: StatusCodes.Status503ServiceUnavailable);
        return Results.Ok(new { status = "ready", database = "reachable" });
    }
    catch (NpgsqlException)
    {
        return Results.Problem("Database is unavailable.", statusCode: StatusCodes.Status503ServiceUnavailable);
    }
});

app.MapGet("/api/notes", async (NpgsqlDataSource database) =>
{
    var notes = new List<Note>();
    await using var connection = await database.OpenConnectionAsync();
    await using var command = new NpgsqlCommand(
        "SELECT id, body, created_at FROM notes ORDER BY created_at DESC LIMIT 100",
        connection);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
        notes.Add(new Note(reader.GetGuid(0), reader.GetString(1), reader.GetDateTime(2)));
    return Results.Ok(notes);
});

app.MapGet("/api/notes/{id:guid}", async (Guid id, NpgsqlDataSource database) =>
{
    await using var connection = await database.OpenConnectionAsync();
    await using var command = new NpgsqlCommand(
        "SELECT id, body, created_at FROM notes WHERE id = @id",
        connection);
    command.Parameters.AddWithValue("id", id);
    await using var reader = await command.ExecuteReaderAsync();
    if (!await reader.ReadAsync())
        return Results.NotFound();

    return Results.Ok(new Note(reader.GetGuid(0), reader.GetString(1), reader.GetDateTime(2)));
});

app.MapPost("/api/notes", async (CreateNoteRequest request, NpgsqlDataSource database) =>
{
    var body = request.Body?.Trim();
    if (string.IsNullOrWhiteSpace(body) || body.Length > 500)
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            [nameof(request.Body)] = ["Body must contain between 1 and 500 non-whitespace characters."]
        });

    var id = Guid.NewGuid();
    await using var connection = await database.OpenConnectionAsync();
    await using var command = new NpgsqlCommand(
        "INSERT INTO notes (id, body) VALUES (@id, @body) RETURNING created_at",
        connection);
    command.Parameters.AddWithValue("id", id);
    command.Parameters.AddWithValue("body", body);
    var createdAt = (DateTime)(await command.ExecuteScalarAsync())!;
    var note = new Note(id, body, createdAt);
    return Results.Created($"/api/notes/{id}", note);
});

app.Run();
await dataSource.DisposeAsync();

record CreateNoteRequest(string? Body);
record Note(Guid Id, string Body, DateTime CreatedAt);
