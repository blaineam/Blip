//! "What can this connection actually do?" — per-activity grades from a speed-test result.
//! Same thresholds as the Mac's `ConnectionGrades`.

use crate::i18n::t;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Grade {
    F = 0,
    C = 1,
    B = 2,
    A = 3,
}

impl Grade {
    pub fn letter(self) -> &'static str {
        match self {
            Grade::A => "A",
            Grade::B => "B",
            Grade::C => "C",
            Grade::F => "F",
        }
    }
    pub fn word(self) -> String {
        t(match self {
            Grade::A => "great",
            Grade::B => "good",
            Grade::C => "struggles",
            Grade::F => "won't work",
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CategoryGrade {
    pub id: &'static str,
    pub name: String,
    pub grade: Grade,
}

pub fn evaluate(
    down: f64,
    up: Option<f64>,
    unloaded_ms: Option<f64>,
    loaded_ms: Option<f64>,
) -> Vec<CategoryGrade> {
    let upv = up.unwrap_or(0.0);
    let bloat = loaded_ms.unwrap_or(0.0) - unloaded_ms.unwrap_or(0.0);
    let tg = |v: f64, a: f64, b: f64, c: f64| {
        if v >= a {
            Grade::A
        } else if v >= b {
            Grade::B
        } else if v >= c {
            Grade::C
        } else {
            Grade::F
        }
    };
    let cap = |g: Grade| -> Grade {
        let Some(loaded) = loaded_ms else {
            return g.min(Grade::B);
        };
        if loaded > 300.0 || bloat > 250.0 {
            return g.min(Grade::F);
        }
        if loaded > 150.0 || bloat > 100.0 {
            return g.min(Grade::C);
        }
        g
    };
    let call = tg(down, 10.0, 4.0, 1.5).min(tg(upv, 5.0, 2.5, 1.0));
    vec![
        CategoryGrade {
            id: "browse",
            name: t("Browsing"),
            grade: tg(down, 25.0, 10.0, 3.0),
        },
        CategoryGrade {
            id: "hd",
            name: t("HD streaming"),
            grade: tg(down, 15.0, 8.0, 5.0),
        },
        CategoryGrade {
            id: "4k",
            name: t("4K streaming"),
            grade: tg(down, 50.0, 25.0, 15.0),
        },
        CategoryGrade {
            id: "calls",
            name: t("Video calls"),
            grade: cap(call),
        },
        CategoryGrade {
            id: "gaming",
            name: t("Cloud gaming"),
            grade: cap(tg(down, 45.0, 25.0, 10.0)),
        },
        CategoryGrade {
            id: "uploads",
            name: t("Big uploads"),
            grade: tg(upv, 100.0, 30.0, 10.0),
        },
    ]
}

pub fn share_line(grades: &[CategoryGrade]) -> String {
    grades
        .iter()
        .map(|g| format!("{} {}", g.grade.letter(), g.name))
        .collect::<Vec<_>>()
        .join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bufferbloat_caps_interactive_grades() {
        let g = evaluate(900.0, Some(800.0), Some(9.0), Some(400.0));
        let calls = g.iter().find(|g| g.id == "calls").unwrap();
        assert_eq!(calls.grade, Grade::F);
        assert_eq!(g.iter().find(|g| g.id == "4k").unwrap().grade, Grade::A);
    }

    #[test]
    fn unmeasured_latency_caps_at_b() {
        let g = evaluate(900.0, Some(800.0), None, None);
        assert_eq!(g.iter().find(|g| g.id == "gaming").unwrap().grade, Grade::B);
    }
}
