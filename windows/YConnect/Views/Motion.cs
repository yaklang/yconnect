using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace YConnect.Views
{
    public sealed class Motion
    {
        private readonly FrameworkElement visual;
        private readonly TranslateTransform translation = new TranslateTransform();
        private int revision;
        public static bool Allowed => SystemParameters.ClientAreaAnimation && (((App)Application.Current).Controller?.Store.Preferences.AnimationsEnabled ?? true);
        public Motion(FrameworkElement visual) { this.visual = visual; visual.RenderTransform = translation; }
        public void Show(double offset = 8)
        {
            revision++; visual.BeginAnimation(UIElement.OpacityProperty, null); translation.BeginAnimation(TranslateTransform.YProperty, null);
            visual.Opacity = 1; translation.Y = 0;
            if (!Allowed) return;
            visual.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(170)));
            translation.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(offset, 0, TimeSpan.FromMilliseconds(230)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        }
        public void Hide(Action complete)
        {
            var token = ++revision;
            if (!Allowed) { complete(); return; }
            var fade = new DoubleAnimation(visual.Opacity, 0, TimeSpan.FromMilliseconds(120));
            fade.Completed += (s, e) => { if (revision == token) complete(); };
            visual.BeginAnimation(UIElement.OpacityProperty, fade);
        }
        public void Cancel() { revision++; visual.BeginAnimation(UIElement.OpacityProperty, null); translation.BeginAnimation(TranslateTransform.YProperty, null); visual.Opacity = 1; translation.Y = 0; }
        public static void Page(FrameworkElement visual) { if (Allowed) new Motion(visual).Show(5); }
    }
}
