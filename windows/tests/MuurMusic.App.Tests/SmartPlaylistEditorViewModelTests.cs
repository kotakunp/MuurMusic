using MuurMusic.App.ViewModels;
using MuurMusic.Core.Models;

namespace MuurMusic.App.Tests;

public class SmartPlaylistEditorViewModelTests
{
    private static (FakeTrackRepository Tracks, FakePlaylistRepository Playlists, SmartPlaylistEditorViewModel Vm) Create()
    {
        var tracks = new FakeTrackRepository();
        var playlists = new FakePlaylistRepository();
        return (tracks, playlists, new SmartPlaylistEditorViewModel(tracks, playlists));
    }

    [Fact]
    public void NewDefinition_SeedsOneEmptyRule()
    {
        var (_, _, vm) = Create();
        vm.NewDefinition("Chill cats");
        Assert.Equal("Chill cats", vm.Name);
        Assert.Single(vm.Rules);
        Assert.False(vm.IsValid); // rule incomplete -> not valid
    }

    [Fact]
    public void BuildDefinition_MapsMatchSortLimitAndCompleteRulesOnly()
    {
        var (_, _, vm) = Create();
        vm.NewDefinition("Test");
        vm.MatchIndex = 1; // any
        vm.SortText = "-rating";
        vm.Limit = 25;
        vm.Rules[0].Field = "genre";
        vm.Rules[0].Op = "is";
        vm.Rules[0].Value = "Jazz";
        vm.AddRuleCommand.Execute(null); // second rule left incomplete

        var def = vm.BuildDefinition();

        Assert.Equal("any", def.Match);
        Assert.Equal("-rating", def.Sort);
        Assert.Equal(25, def.Limit);
        Assert.Single(def.Rules); // incomplete rule dropped
        Assert.Equal("genre", def.Rules[0].Field);
        Assert.Equal("is", def.Rules[0].Op);
        Assert.Equal("Jazz", def.Rules[0].Value?.ToString());
    }

    [Fact]
    public void NumericRule_SerializesValueAsNumber_AndRoundTrips()
    {
        var (_, _, vm) = Create();
        vm.NewDefinition("Rated");
        var rule = vm.Rules[0];
        rule.Field = "rating";
        rule.Op = "between";
        rule.Value = "3";
        rule.Value2 = "5";

        var built = rule.ToRule();
        Assert.True(built.Value is System.Text.Json.Nodes.JsonValue);
        Assert.True(((System.Text.Json.Nodes.JsonValue)built.Value!).TryGetValue<double>(out var lo) && lo == 3);
        Assert.True(((System.Text.Json.Nodes.JsonValue)built.Value2!).TryGetValue<double>(out var hi) && hi == 5);

        var back = SmartRuleItem.From(built, vm);
        Assert.Equal("rating", back.Field);
        Assert.Equal("between", back.Op);
        Assert.Equal("3", back.Value);
        Assert.Equal("5", back.Value2);
        Assert.True(back.IsComplete);
    }

    [Fact]
    public void BetweenRule_RequiresSecondValue()
    {
        var (_, _, vm) = Create();
        vm.NewDefinition("x");
        var rule = vm.Rules[0];
        rule.Field = "rating";
        rule.Op = "between";
        rule.Value = "3";
        Assert.False(rule.IsComplete); // missing Value2
        rule.Value2 = "5";
        Assert.True(rule.IsComplete);
        Assert.True(vm.IsValid); // name set + one complete rule
    }

    [Fact]
    public async Task SaveAsync_CreatesNewPlaylist_WhenNoExistingId()
    {
        var (_, playlists, vm) = Create();
        vm.NewDefinition("Fresh");
        vm.Rules[0].Field = "genre";
        vm.Rules[0].Op = "contains";
        vm.Rules[0].Value = "rock";

        var saved = await vm.SaveAsync();

        Assert.NotNull(saved);
        Assert.True(saved!.IsSmart);
        Assert.Equal("Fresh", saved.Name);
        var stored = await playlists.GetAsync(saved.Id);
        Assert.NotNull(stored);
        Assert.NotNull(stored!.Smart);
        Assert.Single(stored.Smart!.Rules);
    }

    [Fact]
    public async Task LoadFrom_ThenSave_UpdatesExistingPlaylist()
    {
        var (_, playlists, vm) = Create();
        var original = await playlists.CreateAsync("Orig", new SmartPlaylistDefinition
        {
            Name = "Orig",
            Match = "all",
            Rules = new List<SmartRule> { new() { Field = "genre", Op = "is", Value = System.Text.Json.Nodes.JsonValue.Create("Jazz") } },
        });

        vm.LoadFrom(original);
        Assert.Equal("Orig", vm.Name);
        Assert.Single(vm.Rules);
        Assert.Equal("genre", vm.Rules[0].Field);
        Assert.Equal("Jazz", vm.Rules[0].Value);

        vm.Name = "Renamed";
        var saved = await vm.SaveAsync();
        Assert.Equal(original.Id, saved!.Id);
        var stored = await playlists.GetAsync(original.Id);
        Assert.Equal("Renamed", stored!.Name);
    }

    [Fact]
    public async Task LiveCount_ReportsMatchesAfterDebounce()
    {
        var (tracks, _, vm) = Create();
        tracks.Seed(
            new Track { Title = "A", Genre = "Jazz" },
            new Track { Title = "B", Genre = "Jazz" },
            new Track { Title = "C", Genre = "Metal" });

        vm.NewDefinition("Jazzy");
        vm.Rules[0].Field = "genre";
        vm.Rules[0].Op = "is";
        vm.Rules[0].Value = "Jazz";

        // Live count refreshes after a 350 ms debounce.
        await Task.Delay(900);
        Assert.Contains("2 track", vm.LiveCount);
    }

    [Fact]
    public void RemoveRule_KeepsAtLeastOneRule()
    {
        var (_, _, vm) = Create();
        vm.NewDefinition("x");
        vm.RemoveRuleCommand.Execute(vm.Rules[0]);
        Assert.Single(vm.Rules); // cannot remove the last rule

        vm.AddRuleCommand.Execute(null);
        vm.RemoveRuleCommand.Execute(vm.Rules[0]);
        Assert.Single(vm.Rules);
    }
}
