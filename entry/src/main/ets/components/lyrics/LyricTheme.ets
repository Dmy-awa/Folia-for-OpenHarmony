/**
 * Folia HarmonyOS - 歌词主题
 *
 * 上游有 10+ 套全屏歌词动画主题（浮名/流光/心象/云阶/群唱/倾诉/镜台/时计…）。
 * 鸿蒙版先移植三套最具代表性的排版氛围，其余通过新增主题定义扩展：
 *   fume  浮名 —— 居中小字、柔和发光、留白大，适合安静的歌
 *   lumi  流光 —— 大字号、逐字扫光、高对比，适合快歌
 *   cad   心象 —— 多行堆叠、译文并排、信息密度高，适合需要看翻译的场景
 *
 * 主题只描述「怎么画」，不参与解析与时间轴计算。
 */
import { LyricLine } from '../../core/Types';

/** 歌词主题定义 */
export interface LyricTheme {
  id: string;
  name: string;
  /** 页面背景（通常叠加在封面上） */
  background: string;
  /** 封面遮罩透明度 0~1 */
  backdropOpacity: number;
  /** 正文已唱颜色 */
  sungColor: string;
  /** 正文未唱颜色 */
  unsungColor: string;
  /** 当前行颜色 */
  activeColor: string;
  /** 逐字扫光的强调色 */
  highlightColor: string;
  /** 翻译颜色 */
  translationColor: string;
  /** 主字号相对窗口高度的比例 */
  fontSizeRatio: number;
  /** 行间距倍数 */
  lineGapRatio: number;
  /** 当前行放大倍数 */
  activeScale: number;
  /** 非当前行的透明度 */
  inactiveOpacity: number;
  /** 是否展示译文 */
  showTranslation: boolean;
  /** 是否做逐字高亮（需要逐字时轴） */
  wordHighlight: boolean;
  /** 文本对齐 */
  align: TextAlign;
}

const FUME: LyricTheme = {
  id: 'fume',
  name: '浮名',
  background: '#FF07080C',
  backdropOpacity: 0.82,
  sungColor: '#B3F2F4F8',
  unsungColor: '#59F2F4F8',
  activeColor: '#FFF7FAFF',
  highlightColor: '#FF9CCBFF',
  translationColor: '#8CA8C4E8',
  fontSizeRatio: 0.085,
  lineGapRatio: 1.85,
  activeScale: 1.06,
  inactiveOpacity: 0.42,
  showTranslation: true,
  wordHighlight: true,
  align: TextAlign.Center
};

const LUMI: LyricTheme = {
  id: 'lumi',
  name: '流光',
  background: '#FF05070E',
  backdropOpacity: 0.72,
  sungColor: '#CCFFFFFF',
  unsungColor: '#4DFFFFFF',
  activeColor: '#FFFFFFFF',
  highlightColor: '#FF7DB8FF',
  translationColor: '#99B9D6FF',
  fontSizeRatio: 0.115,
  lineGapRatio: 1.6,
  activeScale: 1.12,
  inactiveOpacity: 0.32,
  showTranslation: true,
  wordHighlight: true,
  align: TextAlign.Center
};

const CAD: LyricTheme = {
  id: 'cad',
  name: '心象',
  background: '#FF0A0B10',
  backdropOpacity: 0.88,
  sungColor: '#C7E6EEFF',
  unsungColor: '#4DE6EEFF',
  activeColor: '#FFFFFFFF',
  highlightColor: '#FFA8D2FF',
  translationColor: '#B39FB8D8',
  fontSizeRatio: 0.072,
  lineGapRatio: 2.05,
  activeScale: 1.03,
  inactiveOpacity: 0.5,
  showTranslation: true,
  wordHighlight: false,
  align: TextAlign.Start
};

export const LYRIC_THEMES: LyricTheme[] = [FUME, LUMI, CAD];

export const DEFAULT_THEME_ID: string = 'fume';

export function resolveTheme(themeId: string): LyricTheme {
  for (const theme of LYRIC_THEMES) {
    if (theme.id === themeId) {
      return theme;
    }
  }
  return FUME;
}

/** 把 vp 高度换算成歌词主字号（vp），并做上下限约束 */
export function themeFontSize(theme: LyricTheme, stageHeightVp: number): number {
  const raw = stageHeightVp * theme.fontSizeRatio;
  return Math.max(18, Math.min(raw, 64));
}

/** 主题是否可以对某一行做逐字高亮 */
export function canHighlightWords(theme: LyricTheme, line: LyricLine): boolean {
  return theme.wordHighlight && line.words.length > 1 && !line.isInterlude;
}
