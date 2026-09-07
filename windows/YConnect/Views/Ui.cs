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
        public static Viewbox FitText(string value, double size, string color = "Ink", bool semibold = true)
        {
            var text = Text(value, size, color, semibold); text.TextWrapping = TextWrapping.NoWrap;
            return new Viewbox { Child = text, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left };
        }
        public static StackPanel Stack(params UIElement[] children) { var panel = new StackPanel(); foreach (var child in children) if (child != null) panel.Children.Add(child); return panel; }
        public static StackPanel Row(params UIElement[] children) { var panel = Stack(children); panel.Orientation = Orientation.Horizontal; foreach (var child in children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center; return panel; }
        public static TextBlock Label(string value, double size = 12, string color = "Ink", bool semibold = false)
        {
            var text = Text(value, size, color, semibold); text.TextWrapping = TextWrapping.NoWrap; text.TextTrimming = TextTrimming.CharacterEllipsis; return text;
        }
        public static Grid IconLabel(UIElement icon, UIElement label, double iconSize = 28, double gap = 10)
        {
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(iconSize) }); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(gap) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            if (icon is FrameworkElement mark) { mark.VerticalAlignment = VerticalAlignment.Center; mark.HorizontalAlignment = HorizontalAlignment.Center; }
            if (label is FrameworkElement text) text.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(icon); Grid.SetColumn(label, 2); grid.Children.Add(label); return grid;
        }
        public static FrameworkElement Gap(double height = 14) => new Border { Height = height };
        public static Border Divider() { var line = new Border { Height = 1, Margin = new Thickness(0, 8, 0, 8) }; line.SetResourceReference(Border.BackgroundProperty, "Line"); return line; }
        public static TextBox Selectable(string value, double size = 11) => new TextBox { Text = value, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0), MinHeight = 0, FontSize = size, TextWrapping = TextWrapping.Wrap, FocusVisualStyle = null };
        public static Button SmallButton(string text, string id, Action action, string style = "Quiet") { var b = Button(text, id, action, style); b.FontSize = 11; b.MinHeight = 26; b.Padding = new Thickness(7, 4, 7, 4); return b; }
        public static Border Avatar(string name, double size = 36)
        {
            var initial = Text(string.IsNullOrWhiteSpace(name) ? "Y" : name.Substring(0, 1), size * .42, "Accent", true); initial.HorizontalAlignment = HorizontalAlignment.Center; initial.VerticalAlignment = VerticalAlignment.Center;
            var result = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Child = initial }; result.SetResourceReference(Border.BackgroundProperty, "AccentSoft"); return result;
        }
        public static FrameworkElement QuotaBar(double? percentage, double height = 4)
        {
            var track = new Grid { Height = height, ClipToBounds = true }; track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(.001, percentage ?? 0), GridUnitType.Star) }); track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(.001, 100 - (percentage ?? 0)), GridUnitType.Star) });
            var fill = new Border { CornerRadius = new CornerRadius(height / 2) }; fill.SetResourceReference(Border.BackgroundProperty, "Accent"); fill.Visibility = percentage.HasValue ? Visibility.Visible : Visibility.Hidden; track.Children.Add(fill);
            var outer = new Border { CornerRadius = new CornerRadius(height / 2), Child = track }; outer.SetResourceReference(Border.BackgroundProperty, "Line"); return outer;
        }
        public static Grid Between(UIElement left, UIElement right)
        {
            if (left is FrameworkElement a) a.VerticalAlignment = VerticalAlignment.Center;
            if (right is FrameworkElement b) b.VerticalAlignment = VerticalAlignment.Center;
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(left); Grid.SetColumn(right, 1); grid.Children.Add(right); return grid;
        }
        public static Border Card(UIElement content, double padding = 16, string background = "Surface")
        {
            var b = new Border { Child = content, Padding = new Thickness(padding), CornerRadius = new CornerRadius(13), BorderThickness = new Thickness(1) }; b.SetResourceReference(Border.BackgroundProperty, background); b.SetResourceReference(Border.BorderBrushProperty, "Line"); return b;
        }
        public static Button Button(string text, string id, Action clicked = null, string style = null)
        {
            var caption = new TextBlock { Text = text, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis };
            var b = Id(new Button { Content = caption }, id); AutomationProperties.SetName(b, text);
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
            var mark = new System.Windows.Shapes.Path { Data = Geometry.Parse("F1 M806.668 433.586C788.436 369.392 749.804 312.902 696.629 272.68C643.454 232.459 578.636 210.699 512 210.699C445.365 210.699 380.547 232.459 327.372 272.68C274.197 312.902 235.565 369.392 217.332 433.586C176.66 450.435 143.084 480.894 122.328 519.768C101.573 558.642 94.9241 603.523 103.516 646.759C112.108 689.994 135.408 728.905 169.443 756.857C203.478 784.808 246.141 800.068 290.154 800.035H733.847C777.86 800.068 820.523 784.808 854.558 756.857C888.593 728.905 911.893 689.994 920.485 646.759C929.077 603.523 922.428 558.642 901.672 519.768C880.917 480.894 847.34 450.435 806.668 433.586ZM436.291 549.622C436.291 553.364 434.807 556.952 432.165 559.598C429.524 562.244 425.941 563.73 422.206 563.73H397.556C393.82 563.73 390.238 562.244 387.596 559.598C384.954 556.952 383.47 553.364 383.47 549.622V422.652C383.47 418.91 384.954 415.322 387.596 412.676C390.238 410.031 393.82 408.544 397.556 408.544H422.206C425.941 408.544 429.524 410.031 432.165 412.676C434.807 415.322 436.291 418.91 436.291 422.652V549.622ZM563.06 704.808H460.941V678.356C460.941 664.792 466.32 651.784 475.896 642.194C485.471 632.603 498.458 627.215 512 627.215C525.542 627.215 538.53 632.603 548.105 642.194C557.681 651.784 563.06 664.792 563.06 678.356V704.808ZM640.53 549.622C640.53 553.364 639.046 556.952 636.405 559.598C633.763 562.244 630.181 563.73 626.445 563.73H601.795C598.06 563.73 594.477 562.244 591.835 559.598C589.194 556.952 587.71 553.364 587.71 549.622V422.652C587.71 418.91 589.194 415.322 591.835 412.676C594.477 410.031 598.06 408.544 601.795 408.544H626.445C630.181 408.544 633.763 410.031 636.405 412.676C639.046 415.322 640.53 418.91 640.53 422.652V549.622Z"), Fill = new SolidColorBrush(Color.FromRgb(184, 106, 75)), RenderTransform = new TranslateTransform(-100, -211) };
            var canvas = new Canvas { Width = 824, Height = 589 }; canvas.Children.Add(mark);
            return new Border { Width = size, Height = size, Child = new Viewbox { Child = canvas, Stretch = Stretch.Uniform } };
        }
        public static Border AppMark(ClientDescriptor descriptor, double size = 35)
        {
            var mark = Text(descriptor.Mark, 18, "Accent", true); mark.HorizontalAlignment = HorizontalAlignment.Center; mark.VerticalAlignment = VerticalAlignment.Center;
            var b = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(9), Child = mark }; b.SetResourceReference(Border.BackgroundProperty, "AccentSoft"); return b;
        }
        public static Grid Columns(int count, params UIElement[] children)
        {
            var grid = new Grid(); for (var i = 0; i < count; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
            for (var i = 0; i < children.Length; i++) { if (i % count == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var child = children[i]; Grid.SetColumn(child, i % count); Grid.SetRow(child, i / count); if (child is FrameworkElement e) e.Margin = new Thickness(i % count == 0 ? 0 : 5, 0, i % count == count - 1 ? 0 : 5, 8); grid.Children.Add(child); }
            return grid;
        }
        public static Grid AdaptiveColumns(int maximum, double minimumWidth, params UIElement[] children)
        {
            var grid = Columns(maximum, children);
            grid.SizeChanged += (s, e) =>
            {
                var count = Math.Max(1, Math.Min(maximum, (int)((e.NewSize.Width + 10) / (minimumWidth + 10))));
                if (count == grid.ColumnDefinitions.Count) return;
                grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
                for (var i = 0; i < count; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
                for (var i = 0; i < children.Length; i++)
                {
                    if (i % count == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                    Grid.SetColumn(children[i], i % count); Grid.SetRow(children[i], i / count);
                    if (children[i] is FrameworkElement item) item.Margin = new Thickness(i % count == 0 ? 0 : 5, 0, i % count == count - 1 ? 0 : 5, 8);
                }
            };
            return grid;
        }
        public static Grid SearchField(TextBox input, string hint)
        {
            var field = new Grid(); field.Children.Add(input);
            var placeholder = Label(hint, input.FontSize, "Muted"); placeholder.Margin = new Thickness(11, 0, 11, 0); placeholder.VerticalAlignment = VerticalAlignment.Center; placeholder.IsHitTestVisible = false;
            field.Children.Add(placeholder); Action update = () => placeholder.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Hidden;
            input.TextChanged += (s, e) => update(); update(); return field;
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
        public static bool HasFeedback(YConnectStore store) => !string.IsNullOrEmpty(store.Error) || !string.IsNullOrEmpty(store.Warning) || (!string.IsNullOrEmpty(store.Message) && !new[] { "YAKCOOL 账户已安全连接", "API Key 已安全连接", "信息已刷新", "已退出登录" }.Contains(store.Message));
        public static void SetTheme(string theme)
        {
            var dark = theme == "dark";
            var values = dark ? new[] { "#20201F", "#292928", "#323230", "#F1EEE8", "#ACA8A1", "#42413E", "#D9917C", "#43332D", "#8EC8A3", "#2B3930", "#EC9891" } : new[] { "#F6F4F0", "#FFFFFF", "#F7F5F1", "#302D29", "#78746D", "#EAE6DF", "#B86A4B", "#F8EBE5", "#32805A", "#EAF3EC", "#B34949" };
            var names = new[] { "Page", "Surface", "SurfaceAlt", "Ink", "Muted", "Line", "Accent", "AccentSoft", "Green", "GreenSoft", "Danger" };
            for (var i = 0; i < names.Length; i++) Application.Current.Resources[names[i]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(values[i]));
            Application.Current.Resources["Sidebar"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? "#242321" : "#E8E2D9"));
            Application.Current.Resources["WindowFrame"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? "#615C54" : "#BDB3A5"));
            Application.Current.Resources["NavSelected"] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(dark ? "#44352F" : "#FAF6F0"));
        }
    }
}
