using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using YConnect.Core;

namespace YConnect.Views
{
    public static class Ui
    {
        public static Brush Brush(string name) => Application.Current.TryFindResource(name) as Brush ?? new SolidColorBrush((Color)ColorConverter.ConvertFromString(name));
        public static T Id<T>(T item, string id) where T : DependencyObject { AutomationProperties.SetAutomationId(item, id); return item; }
        public static TextBlock Text(string value, double size = 13, string color = "Ink", bool semibold = false)
        {
            var t = new TextBlock { Text = value ?? "", FontSize = size, FontWeight = semibold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap }; t.SetResourceReference(TextBlock.ForegroundProperty, color); return t;
        }
        public static TextBlock Glyph(string value, double size = 17, string color = "Muted") { var t = Text(value, size, color); t.FontFamily = new FontFamily("Segoe MDL2 Assets"); t.VerticalAlignment = VerticalAlignment.Center; return t; }
        public static StackPanel Stack(params UIElement[] children) { var panel = new StackPanel(); foreach (var child in children) if (child != null) panel.Children.Add(child); return panel; }
        public static StackPanel Row(params UIElement[] children) { var panel = Stack(children); panel.Orientation = Orientation.Horizontal; return panel; }
        public static FrameworkElement Gap(double height = 14) => new Border { Height = height };
        public static Grid Between(UIElement left, UIElement right)
        {
            if (left is FrameworkElement a) a.VerticalAlignment = VerticalAlignment.Center;
            if (right is FrameworkElement b) b.VerticalAlignment = VerticalAlignment.Center;
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(left); Grid.SetColumn(right, 1); grid.Children.Add(right); return grid;
        }
        public static Border Card(UIElement content, double padding = 20, string background = "Surface")
        {
            var b = new Border { Child = content, Padding = new Thickness(padding), CornerRadius = new CornerRadius(13), BorderThickness = new Thickness(1) }; b.SetResourceReference(Border.BackgroundProperty, background); b.SetResourceReference(Border.BorderBrushProperty, "Line"); return b;
        }
        public static Button Button(string text, string id, Action clicked = null, string style = null)
        {
            var b = Id(new Button { Content = text }, id); AutomationProperties.SetName(b, text);
            if (style != null) b.SetResourceReference(FrameworkElement.StyleProperty, style);
            if (clicked != null) b.Click += (s, e) => clicked(); return b;
        }
        public static Button AsyncButton(string text, string id, Func<Task> clicked, string style = null)
        {
            var b = Button(text, id, null, style); b.Click += async (s, e) => { try { await clicked(); } catch (Exception error) { ((App)Application.Current).Controller?.Store.SetError(error.Message); } }; return b;
        }
        public static Button IconButton(string glyph, string label, string id, Action clicked)
        {
            var b = Button("", id, clicked, "Quiet"); b.Content = Glyph(glyph, 15); b.ToolTip = label; b.Padding = new Thickness(8); b.MinWidth = 30; b.MinHeight = 30; AutomationProperties.SetName(b, label); return b;
        }
        public static Border Badge(string text, string foreground = "Green", string background = "GreenSoft")
        {
            var b = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 4, 8, 4), Child = Text(text, 10, foreground, true), VerticalAlignment = VerticalAlignment.Center }; b.SetResourceReference(Border.BackgroundProperty, background); return b;
        }
        public static Border Logo(double size = 38)
        {
            var geometry = new PathGeometry(new[] { new PathFigure(new Point(11, 11), new PathSegment[] { new LineSegment(new Point(19, 21), true), new LineSegment(new Point(27, 11), true) }, false), new PathFigure(new Point(19, 21), new PathSegment[] { new LineSegment(new Point(19, 29), true) }, false) });
            var mark = new System.Windows.Shapes.Path { Data = geometry, Stroke = Brushes.White, StrokeThickness = 3.1, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };
            var canvas = new Canvas { Width = 38, Height = 38 }; canvas.Children.Add(mark);
            return new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size * .27), Background = new LinearGradientBrush(Color.FromRgb(201, 120, 97), Color.FromRgb(173, 87, 66), 90), Child = new Viewbox { Child = canvas } };
        }
        public static Border AppMark(ClientDescriptor descriptor, double size = 35)
        {
            var mark = Text(descriptor.Mark, 18, "Accent", true); mark.HorizontalAlignment = HorizontalAlignment.Center; mark.VerticalAlignment = VerticalAlignment.Center;
            var b = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(9), Child = mark }; b.SetResourceReference(Border.BackgroundProperty, "AccentSoft"); return b;
        }
        public static Grid Columns(int count, params UIElement[] children)
        {
            var grid = new Grid(); for (var i = 0; i < count; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
            for (var i = 0; i < children.Length; i++) { if (i % count == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var child = children[i]; Grid.SetColumn(child, i % count); Grid.SetRow(child, i / count); if (child is FrameworkElement e) e.Margin = new Thickness(i % count == 0 ? 0 : 6, 0, i % count == count - 1 ? 0 : 6, 12); grid.Children.Add(child); }
            return grid;
        }
        public static string Protocol(string id) => id == "responses" ? "Responses" : id == "anthropic_messages" ? "Messages" : id == "chat_completions" ? "Chat Completions" : id;
        public static string Status(ClientStatus status) => status.State == "configured" ? "已配置" : status.State == "drifted" ? "配置已变化" : status.State == "invalid" ? "需要检查" : "待接入";
        public static Border Notice(string text, bool error = false) => Card(Text(text, 12, error ? "Danger" : "Muted"), 12, error ? "AccentSoft" : "SurfaceAlt");
        public static FrameworkElement Feedback(YConnectStore store)
        {
            if (!string.IsNullOrEmpty(store.Error)) return Notice(store.Error, true);
            if (!string.IsNullOrEmpty(store.Warning)) return Notice(store.Warning);
            if (!string.IsNullOrEmpty(store.Message)) return Notice(store.Message);
            return new Border();
        }
        public static bool HasFeedback(YConnectStore store) => !string.IsNullOrEmpty(store.Error) || !string.IsNullOrEmpty(store.Warning) || (!string.IsNullOrEmpty(store.Message) && !new[] { "YakCool 账户已安全连接", "API Key 已安全连接", "信息已刷新", "已退出登录" }.Contains(store.Message));
        public static void SetTheme(string theme)
        {
            var dark = theme == "dark";
            var values = dark ? new[] { "#1D2320", "#252D28", "#303932", "#E6EBE5", "#A0ACA2", "#3B463D", "#D79377", "#40352C", "#8CC2A2", "#2B3B31", "#ED9692" } : new[] { "#F6F5F1", "#FFFFFF", "#F1F0EB", "#292E2C", "#737C77", "#E4E6E0", "#B96953", "#F7EAE3", "#3B7860", "#EBF3ED", "#B34949" };
            var names = new[] { "Page", "Surface", "SurfaceAlt", "Ink", "Muted", "Line", "Accent", "AccentSoft", "Green", "GreenSoft", "Danger" };
            for (var i = 0; i < names.Length; i++) Application.Current.Resources[names[i]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(values[i]));
        }
    }
}
