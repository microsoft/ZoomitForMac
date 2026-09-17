//! Annotation model shared across platforms.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnnotationTool {
    Pen,
    Line,
    Rectangle,
    Ellipse,
    Arrow,
    Text,
    Highlighter,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnnotationColor {
    Red,
    Green,
    Blue,
    Yellow,
    Orange,
    Pink,
    White,
    Black,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnnotationStyle {
    pub color: AnnotationColor,
    pub root_width: f32,
    pub alpha: f32,
}

impl Default for AnnotationStyle {
    fn default() -> Self {
        Self {
            color: AnnotationColor::Red,
            root_width: 5.0,
            alpha: 1.0,
        }
    }
}

impl AnnotationStyle {
    pub const HIGHLIGHT_ALPHA: f32 = 0.5;
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Annotation {
    pub tool: AnnotationTool,
    pub points: Vec<Point>,
    pub style: AnnotationStyle,
    pub text: String,
}

impl Annotation {
    pub fn new(tool: AnnotationTool, style: AnnotationStyle) -> Self {
        Self {
            tool,
            points: Vec::new(),
            style,
            text: String::new(),
        }
    }

    pub fn add_point(&mut self, x: f32, y: f32) {
        self.points.push(Point { x, y });
    }
}

/// Simple undoable list of annotations.
#[derive(Debug, Default)]
pub struct AnnotationStore {
    items: Vec<Annotation>,
}

impl AnnotationStore {
    pub fn push(&mut self, a: Annotation) {
        self.items.push(a);
    }

    pub fn undo(&mut self) -> Option<Annotation> {
        self.items.pop()
    }

    pub fn clear(&mut self) {
        self.items.clear();
    }

    pub fn iter(&self) -> impl Iterator<Item = &Annotation> {
        self.items.iter()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_undo() {
        let mut s = AnnotationStore::default();
        s.push(Annotation::new(AnnotationTool::Pen, AnnotationStyle::default()));
        assert_eq!(s.len(), 1);
        s.undo();
        assert!(s.is_empty());
    }
}
