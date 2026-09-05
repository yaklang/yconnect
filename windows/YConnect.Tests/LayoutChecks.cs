using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using YConnect;
using YConnect.Core;
using YConnect.Views;

// Renders the application's content trees without showing windows or sending desktop input.
internal static class LayoutChecks
{
    // WPF queues OnStartup even without Application.Run; never start production services in a renderer.
    private sealed class RenderApplication : App { protected override void OnStartup(StartupEventArgs e) { } }
    private static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    private static IEnumerable<T> All<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match) yield return match;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            foreach (var child in All<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static T Find<T>(DependencyObject root, string id) where T : DependencyObject => All<T>(root).Single(x => AutomationProperties.GetAutomationId(x) == id);
    private static void Layout(FrameworkElement root, double width, double height)
    {
        for (var pass = 0; pass < 3; pass++)
        {
            root.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
            root.InvalidateMeasure(); root.InvalidateArrange();
            root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, double.IsInfinity(height) ? root.DesiredSize.Height : height)); root.UpdateLayout();
        }
    }
    private static void Save(FrameworkElement root, string directory, string name)
    {
        foreach (var scale in new[] { 1d, 1.25, 1.5 })
        {
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling((root.ActualWidth + root.Margin.Left + root.Margin.Right) * scale), (int)Math.Ceiling((root.ActualHeight + root.Margin.Top + root.Margin.Bottom) * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            bitmap.Render(root); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(Path.Combine(directory, name + "-" + (scale * 100).ToString("0") + ".png"))) encoder.Save(file);
        }
    }
    private static void Section(WidgetWindow widget, string value)
    {
        var connection = typeof(WidgetWindow).GetField("connection", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(widget);
        typeof(ConnectionPanel).GetField("expanded", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(connection, value);
        widget.Render();
    }
    public static void Run(string output)
    {
        Exception failure = null;
        var thread = new Thread(() => { try { RunCore(output); } catch (Exception error) { failure = error; } finally { Application.Current?.Shutdown(); } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        if (!thread.Join(TimeSpan.FromSeconds(45))) throw new TimeoutException("Headless WPF render exceeded 45 seconds.");
        if (failure != null) throw new Exception("Headless WPF render: " + failure.Message, failure);
    }
    private static void RunCore(string output)
    {
        Directory.CreateDirectory(output);
        var environment = new EnvironmentPaths(true, true, Path.Combine(output, "sandbox"));
        var store = new YConnectStore(environment, new DemoApi()); store.LoginAccount("demo-public-session-only", false).GetAwaiter().GetResult();
        var application = new RenderApplication { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/YConnect;component/Views/Theme.xaml", UriKind.Relative) });
        using (var app = new AppController(store))
        {
            typeof(App).GetProperty("Controller").SetValue(application, app, null);
            app.Widget.IsDragging = true; store.Preferences.AnimationsEnabled = false;
            store.Preferences.SidebarCollapsed = true;
            var manager = app.Manager; Require(!manager.SidebarCollapsed, "Manager must start expanded, even with a previously collapsed preference.");
            var root = (FrameworkElement)manager.Content;
            foreach (var theme in new[] { "light", "dark" })
            {
                Ui.SetTheme(theme); manager.Navigate("overview"); Layout(root, 1080, 760);
                Require(ReferenceEquals(application.Controller, app) && !Motion.Allowed, "Rendering must not start production services or animations.");
                Require(((SolidColorBrush)Ui.Brush("Sidebar")).Color != ((SolidColorBrush)Ui.Brush("Surface")).Color, "Sidebar must be distinct from content.");
                foreach (var id in new[] { "key-select", "copy-key", "copy-access", "new-key", "protocols", "model-search", "refresh", "pin", "checks", "redeem", "signout", "settings", "keys" })
                    Require(All<FrameworkElement>(root).Any(x => AutomationProperties.GetAutomationId(x) == "overview-" + id), "Overview missing " + id);
                foreach (var client in store.Clients.InstalledClients(store.Preferences.RecentClients)) Find<Button>(root, "overview-client-" + client.Id);
                Save(root, output, theme + "-overview");
                Layout(root, 850, 640);
                var clientGrid = (Grid)VisualTreeHelper.GetParent(Find<Button>(root, "overview-client-opencode"));
                Require(clientGrid.ColumnDefinitions.Count == 1, "Narrow client cards should use one readable column.");
                Require(Find<Button>(root, "sidebar-account").TranslatePoint(new Point(0, 34), root).Y < 640, "Account footer clipped.");
                Save(root, output, theme + "-overview-narrow");
                Layout(root, 1080, 760); Require(clientGrid.ColumnDefinitions.Count == 2, "Client grid must return to two columns when widened.");
                manager.Navigate("clients"); Layout(root, 1080, 760);
                var clientButtons = All<Button>(root).Where(x => AutomationProperties.GetAutomationId(x).StartsWith("client-select-")).ToArray();
                Require(clientButtons.Length > 0 && clientButtons.All(x => x.ActualHeight >= 32) && clientButtons.Select(x => x.ActualHeight).Distinct().Count() == 1, "Client rows must be laid out with even heights.");
                Save(root, output, theme + "-clients"); Layout(root, 850, 640); Save(root, output, theme + "-clients-narrow");
                foreach (var section in new[] { "", "protocols", "models" })
                {
                    Section(app.Widget, section); var widgetRoot = (FrameworkElement)app.Widget.Content; Layout(widgetRoot, 400, double.PositiveInfinity);
                    var disclosure = Find<Button>(widgetRoot, "widget-protocols");
                    Require(disclosure.Padding.Left >= 8 && disclosure.MinHeight >= 32, "Disclosure needs safe label spacing.");
                    Require(disclosure.FocusVisualStyle != null, "Keyboard-only focus indication must remain available.");
                    Require(All<FrameworkElement>(disclosure).All(x => x.Name != "FocusRing"), "Mouse focus must not leave the old colliding red outline.");
                    if (section == "protocols") foreach (var endpoint in AppController.Endpoints) Find<Button>(widgetRoot, "endpoint-" + endpoint.Id);
                    Save(widgetRoot, output, theme + "-widget-" + (section.Length == 0 ? "default" : section));
                    if (section == "protocols")
                    {
                        var originalHeight = widgetRoot.ActualHeight;
                        typeof(AppController).GetField("copiedId", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(app, "openai-base");
                        app.Widget.Render(); Layout(widgetRoot, 400, double.PositiveInfinity);
                        Require(Math.Abs(originalHeight - widgetRoot.ActualHeight) < .1, "Copy feedback must not move or resize the widget.");
                        Require(All<TextBlock>(Find<Button>(widgetRoot, "endpoint-openai-base")).Any(x => x.Text == "✓ 已复制" && x.TextWrapping == TextWrapping.NoWrap), "Copy feedback must stay on one line.");
                        Save(widgetRoot, output, theme + "-widget-copied");
                        typeof(AppController).GetField("copiedId", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(app, null);
                    }
                }
            }
            Ui.SetTheme("light");
        }
    }
}
