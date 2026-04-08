using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.Playwright;
using UiTests.PageObjects;
using UiTests.PageObjects.Components;
using UiTests.Utils;

namespace UiTests.PageObjects.Panes.CallTrace;

/// <summary>
/// Pane representing the call trace view and its rendered call hierarchy.
/// </summary>
public class CallTracePane : TabObject
{
    private readonly ContextMenu _contextMenu;
    private List<CallTraceEntry> _entries = new();

    public CallTracePane(IPage page, ILocator root, string tabButtonText)
        : base(page, root, tabButtonText)
    {
        _contextMenu = new ContextMenu(page);
    }

    /// <summary>
    /// Locator referencing the scrolling container of call trace lines.
    /// </summary>
    public ILocator LinesContainer()
        => Root.Locator(".calltrace-lines");

    /// <summary>
    /// Locator for the search input.
    /// </summary>
    public ILocator SearchInput()
        => Root.Locator(".calltrace-search-input");

    /// <summary>
    /// Locator for the search results popup.
    /// </summary>
    public ILocator SearchResultsContainer()
        => Root.Locator(".call-search-results");

    /// <summary>
    /// Waits until call trace entries are rendered.
    /// </summary>
    public Task WaitForReadyAsync()
        => RetryHelpers.RetryAsync(async () =>
            await LinesContainer().Locator(".calltrace-call-line").CountAsync() > 0);

    /// <summary>
    /// Retrieves all currently visible call entries.
    /// </summary>
    public async Task<IReadOnlyList<CallTraceEntry>> EntriesAsync(bool forceReload = false)
    {
        if (forceReload || _entries.Count == 0)
        {
            await WaitForReadyAsync();
            var roots = await LinesContainer().Locator(".calltrace-call-line").AllAsync();
            _entries = roots
                .Select(locator => new CallTraceEntry(this, locator, _contextMenu))
                .ToList();
        }

        return _entries;
    }

    /// <summary>
    /// Clears the cached entry list so the next access reloads the DOM.
    /// </summary>
    public void InvalidateEntries() => _entries.Clear();

    /// <summary>
    /// Finds the first call trace entry whose function name matches <paramref name="functionName"/>.
    /// Entries that are scrolled out of the virtualized viewport may throw Playwright
    /// timeouts when accessed — these are silently skipped.
    /// </summary>
    public async Task<CallTraceEntry?> FindEntryAsync(string functionName, bool forceReload = false)
    {
        var entries = await EntriesAsync(forceReload);
        foreach (var entry in entries)
        {
            try
            {
                var name = await entry.FunctionNameAsync();
                if (string.Equals(name, functionName, StringComparison.OrdinalIgnoreCase))
                {
                    return entry;
                }
            }
            catch (PlaywrightException)
            {
                // Entry is likely scrolled out of the virtualized viewport and its
                // DOM element is inaccessible. Skip it and continue searching.
            }
        }

        return null;
    }

    /// <summary>
    /// Performs a search query within the call trace pane.
    /// </summary>
    public async Task SearchAsync(string query)
    {
        await SearchInput().FillAsync(query);
        await SearchInput().PressAsync("Enter");
        await RetryHelpers.RetryAsync(async () =>
            await SearchResultsContainer().Locator(".search-result").CountAsync() > 0);
    }

    /// <summary>
    /// Clears the search field.
    /// </summary>
    public async Task ClearSearchAsync()
    {
        await SearchInput().FillAsync(string.Empty);
        await RetryHelpers.RetryAsync(async () =>
            await SearchResultsContainer().Locator(".search-result").CountAsync() == 0);
    }

    /// <summary>
    /// Returns the tooltip value currently rendered (if any).
    /// </summary>
    public async Task<ValueComponentView?> ActiveTooltipAsync()
    {
        var tooltip = Root.Locator(".call-tooltip");
        if (await tooltip.CountAsync() == 0)
        {
            return null;
        }

        return new ValueComponentView(tooltip.Locator(".value-expanded").First);
    }

    /// <summary>
    /// Measures how closely the rendered SVG overlay aligns with the marker column
    /// for the visible call trace entry matching <paramref name="functionName"/>.
    /// </summary>
    public Task<CallTraceOverlayAlignment> MeasureOverlayAlignmentAsync(string functionName)
        => Root.EvaluateAsync<CallTraceOverlayAlignment>(
            @"(root, functionName) => {
                const linesContainer = root.querySelector('.calltrace-lines');
                const scrollContainer = root.querySelector('.local-calltrace-view');
                const svg = root.querySelector('svg.calltrace-svg-line');
                if (!linesContainer || !scrollContainer || !svg) {
                    throw new Error('Call trace DOM is missing the lines container, scroll container, or SVG overlay.');
                }

                const rows = Array.from(linesContainer.querySelectorAll('.calltrace-call-line'));
                const row = rows.find((entry) => {
                    const text = (entry.querySelector('.call-text')?.textContent || '').trim();
                    return text.startsWith(functionName + ' #') || text === functionName;
                });
                if (!row) {
                    throw new Error(`Call trace row '${functionName}' is not visible.`);
                }

                const marker = row.querySelector('.collapse-call-img, .expand-call-img, .dot-call-img, .end-of-program-img, .active-call-location')
                    || row.querySelector('.toggle-call');
                if (!marker) {
                    throw new Error(`Call trace row '${functionName}' has no marker anchor.`);
                }

                const linesRect = linesContainer.getBoundingClientRect();
                const markerRect = marker.getBoundingClientRect();
                const markerCenterX = markerRect.left + (markerRect.width / 2) - linesRect.left + scrollContainer.scrollLeft;
                const markerCenterY = markerRect.top + (markerRect.height / 2) - linesRect.top;

                const verticalSegments = Array.from(svg.querySelectorAll('line'))
                    .map((line) => ({
                        x1: Number.parseFloat(line.getAttribute('x1') || 'NaN'),
                        x2: Number.parseFloat(line.getAttribute('x2') || 'NaN'),
                        y1: Number.parseFloat(line.getAttribute('y1') || 'NaN'),
                        y2: Number.parseFloat(line.getAttribute('y2') || 'NaN')
                    }))
                    .filter((segment) =>
                        Number.isFinite(segment.x1) &&
                        Number.isFinite(segment.x2) &&
                        Number.isFinite(segment.y1) &&
                        Number.isFinite(segment.y2) &&
                        Math.abs(segment.x1 - segment.x2) < 0.01 &&
                        markerCenterY >= Math.min(segment.y1, segment.y2) - 0.5 &&
                        markerCenterY <= Math.max(segment.y1, segment.y2) + 0.5);

                if (verticalSegments.length === 0) {
                    throw new Error(`No vertical SVG segment overlaps '${functionName}'.`);
                }

                const bestSegment = verticalSegments
                    .sort((left, right) =>
                        Math.abs(left.x1 - markerCenterX) - Math.abs(right.x1 - markerCenterX))[0];

                return {
                    markerCenterX,
                    overlayX: bestSegment.x1,
                    deltaX: Math.abs(bestSegment.x1 - markerCenterX)
                };
            }",
            functionName);
}

public sealed class CallTraceOverlayAlignment
{
    public double MarkerCenterX { get; set; }
    public double OverlayX { get; set; }
    public double DeltaX { get; set; }
}
