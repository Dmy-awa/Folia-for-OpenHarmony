/**
 * Folia HarmonyOS - 本地音乐库
 *
 * 设计取舍（重要）：
 *   系统文件选择器给出的 URI 只授予**临时**访问权限，应用重启后失效。
 *   要长期访问有两种做法：
 *     a) 申请持久化 URI 权限（fileShare.persistPermission）；
 *     b) 把音频复制进应用沙箱。
 *   本实现选择 (b)：导入时把文件复制到 `filesDir/music/<hash>.<ext>`，
 *   这样路径稳定、不依赖额外权限，且用户删掉外部文件后曲库仍然可用。
 *   代价是占用双份存储；若后续要支持「引用外部目录」，把 `importFiles`
 *   换成 (a) 即可，其余逻辑无需改动。
 *
 * 索引以 JSON 文件形式存放在 `filesDir/folia/library.json`，
 * 相比 preferences 没有单值大小限制，相比关系型数据库实现更轻。
 */
import { common, Want } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import {
  CoverRef,
  LyricFormat,
  LyricPayload,
  ProviderId,
  Track,
  TrackOrigin
} from '../../core/Types';
import {
  AudioMetadata,
  readMetadataFromPath
} from './MetadataReader';
import { decryptKrc } from '../lyrics/KrcDecoder';

const TAG: string = 'LocalLibraryService';

/** 支持的音频扩展名 */
const AUDIO_EXTENSIONS: string[] = ['mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'wma', 'ape'];

/** 歌词侧车文件格式优先级，与上游 localLyricFormatOrder 一致 */
const LYRIC_EXTENSIONS: string[] = ['lrc', 'vtt', 'ttml', 'qrc', 'yrc', 'krc'];

/** 持久化用的索引条目 */
interface LibraryEntry {
  id: string;
  songId: string;
  title: string;
  artist: string;
  artists: string[];
  album: string;
  duration: number;
  fileUri: string;
  fileSize: number;
  coverPath?: string;
  hasEmbeddedLyric: boolean;
  localLyricPath?: string;
  addedAt: number;
}

interface LibraryIndex {
  version: number;
  entries: LibraryEntry[];
}

export class LocalLibraryService {
  private context: common.UIAbilityContext | undefined = undefined;
  private musicDir: string = '';
  private coverDir: string = '';
  private indexPath: string = '';
  private entries: LibraryEntry[] = [];
  /** 内存中的 Track 视图，避免每次遍历都重建对象 */
  private tracks: Track[] = [];
  private loaded: boolean = false;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    const filesDir = context.filesDir;
    this.musicDir = `${filesDir}/music`;
    this.coverDir = `${filesDir}/cover`;
    this.indexPath = `${filesDir}/folia/library.json`;
    this.ensureDir(this.musicDir);
    this.ensureDir(this.coverDir);
    this.ensureDir(`${filesDir}/folia`);
    this.loadIndex();
    Logger.info(TAG, `local library ready, ${this.entries.length} tracks`);
  }

  private ensureDir(path: string): void {
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
    } catch (error) {
      Logger.err(TAG, `mkdir ${path}`, error as Error);
    }
  }

  // -------------------------------------------------------------------------
  // 导入
  // -------------------------------------------------------------------------

  /**
   * 弹出系统文件选择器导入音频文件。
   * @returns 新导入的曲目数量
   */
  async importFromPicker(): Promise<number> {
    const context = this.context;
    if (context === undefined) {
      return 0;
    }
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 200;
    // 只筛音频类型，减少用户误选
    options.fileSuffixFilters = ['音频|.mp3,.flac,.m4a,.aac,.ogg,.opus,.wav,.wma,.ape'];

    let uris: string[] = [];
    try {
      uris = await documentPicker.select(options);
    } catch (error) {
      // 用户取消选择不是错误
      Logger.info(TAG, `picker cancelled or failed: ${(error as BusinessError).message}`);
      return 0;
    }
    if (uris.length === 0) {
      return 0;
    }
    return await this.importUris(uris);
  }

  /**
   * 导入一批 URI：复制进沙箱 -> 读元数据 -> 抽取封面与歌词 -> 落索引。
   * 单个文件失败不会中断整批导入。
   */
  async importUris(uris: string[]): Promise<number> {
    let imported = 0;
    for (const uri of uris) {
      try {
        const entry = await this.importSingle(uri);
        if (entry !== undefined) {
          // 同一文件重复导入时覆盖旧条目
          this.entries = this.entries.filter((e: LibraryEntry) => e.songId !== entry.songId);
          this.entries.push(entry);
          imported += 1;
        }
      } catch (error) {
        Logger.err(TAG, `import ${uri}`, error as Error);
      }
    }
    if (imported > 0) {
      this.rebuildTracks();
      this.saveIndex();
    }
    return imported;
  }

  private async importSingle(uri: string): Promise<LibraryEntry | undefined> {
    const extension = this.extensionOf(uri);
    if (!AUDIO_EXTENSIONS.includes(extension)) {
      Logger.warn(TAG, `skip non-audio: ${uri}`);
      return undefined;
    }
    const songId = this.hashKey(uri);
    const target = `${this.musicDir}/${songId}.${extension}`;

    // 已导入过则直接复用，避免重复拷贝大文件
    if (!fileIo.accessSync(target)) {
      this.copyFile(uri, target);
    }

    const stat = fileIo.statSync(target);
    const metadata = this.readMetadata(target);

    // 抽取内嵌封面为独立文件，避免每次渲染都解析整个音频文件
    let coverPath: string | undefined = undefined;
    if (metadata.cover !== undefined) {
      coverPath = this.writeCover(songId, metadata.cover.mimeType, metadata.cover.data);
    }

    let localLyricPath = this.findSidecarLyric(target);
    const hasEmbeddedLyric = metadata.lyrics !== undefined && metadata.lyrics.trim().length > 0;
    if (localLyricPath === undefined && hasEmbeddedLyric) {
      // 把内嵌歌词落地成侧车文件，后续读取路径统一
      const embeddedPath = `${this.musicDir}/${songId}.embedded.lrc`;
      this.writeText(embeddedPath, metadata.lyrics as string);
      localLyricPath = embeddedPath;
    }

    const title = metadata.title.length > 0 ? metadata.title : this.baseName(uri);
    const artist = metadata.artist.length > 0 ? metadata.artist : '未知艺术家';
    const entry: LibraryEntry = {
      id: `${ProviderId.LOCAL}:${songId}`,
      songId: songId,
      title: title,
      artist: artist,
      artists: metadata.artists.length > 0 ? metadata.artists : [artist],
      album: metadata.album,
      duration: metadata.durationMs,
      fileUri: target,
      fileSize: stat.size,
      coverPath: coverPath,
      hasEmbeddedLyric: hasEmbeddedLyric,
      localLyricPath: localLyricPath,
      addedAt: Date.now()
    };
    return entry;
  }

  /**
   * 读取标签。
   * 容器嗅探与解析都交给 MetadataReader.readMetadataFromPath，避免读两遍文件头。
   * 解析失败时返回空结果而不是抛出——损坏文件不应该阻断整批导入。
   */
  private readMetadata(path: string): AudioMetadata {
    try {
      return readMetadataFromPath(path);
    } catch (error) {
      Logger.err(TAG, `read metadata ${path}`, error as Error);
      const empty: AudioMetadata = {
        title: '',
        artist: '',
        artists: [],
        album: '',
        albumArtist: '',
        trackNumber: 0,
        year: '',
        durationMs: 0,
        sampleRate: 0,
        bitrate: 0,
        channels: 0
      };
      return empty;
    }
  }

  private copyFile(sourceUri: string, target: string): void {
    const src = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
    try {
      const dst = fileIo.openSync(target,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.copyFileSync(src.fd, dst.fd);
      } finally {
        fileIo.closeSync(dst);
      }
    } finally {
      fileIo.closeSync(src);
    }
  }

  private writeCover(songId: string, mimeType: string, data: Uint8Array): string | undefined {
    const extension = mimeType.includes('png') ? 'png' : 'jpg';
    const path = `${this.coverDir}/${songId}.${extension}`;
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, data.buffer as ArrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      return path;
    } catch (error) {
      Logger.err(TAG, 'write cover', error as Error);
      return undefined;
    }
  }

  private writeText(path: string, text: string): void {
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      Logger.err(TAG, `write text ${path}`, error as Error);
    }
  }

  /**
   * 查找同目录同名侧车歌词文件。
   * 按上游的格式优先级顺序探测：lrc -> vtt -> ttml -> qrc -> yrc -> krc。
   */
  private findSidecarLyric(audioPath: string): string | undefined {
    const dot = audioPath.lastIndexOf('.');
    const stem = dot > 0 ? audioPath.slice(0, dot) : audioPath;
    for (const extension of LYRIC_EXTENSIONS) {
      const candidate = `${stem}.${extension}`;
      if (fileIo.accessSync(candidate)) {
        return candidate;
      }
    }
    return undefined;
  }

  // -------------------------------------------------------------------------
  // 查询
  // -------------------------------------------------------------------------

  getAll(): Track[] {
    if (!this.loaded) {
      this.rebuildTracks();
    }
    return this.tracks;
  }

  size(): number {
    return this.entries.length;
  }

  findById(id: string): Track | undefined {
    return this.getAll().find((t: Track) => t.id === id);
  }

  /** 按标题 / 艺术家 / 专辑做本地模糊搜索 */
  search(keyword: string): Track[] {
    const lower = keyword.trim().toLowerCase();
    if (lower.length === 0) {
      return this.getAll();
    }
    return this.getAll().filter((t: Track) => {
      return t.title.toLowerCase().includes(lower)
        || t.artist.toLowerCase().includes(lower)
        || t.album.toLowerCase().includes(lower);
    });
  }

  async removeById(id: string): Promise<void> {
    const entry = this.entries.find((e: LibraryEntry) => e.id === id);
    if (entry === undefined) {
      return;
    }
    this.entries = this.entries.filter((e: LibraryEntry) => e.id !== id);
    this.rebuildTracks();
    this.saveIndex();
    // 沙箱文件一并清理，避免孤儿文件占空间
    this.deleteQuietly(entry.fileUri);
    if (entry.coverPath !== undefined) {
      this.deleteQuietly(entry.coverPath);
    }
    Logger.info(TAG, `removed ${entry.title}`);
  }

  private deleteQuietly(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      Logger.err(TAG, `unlink ${path}`, error as Error);
    }
  }

  // -------------------------------------------------------------------------
  // 歌词
  // -------------------------------------------------------------------------

  /**
   * 读取本地曲目的歌词。
   *
   *  - 普通文本格式（.lrc/.vtt/.ttml/.qrc/.yrc）：直接读文本，并把扩展名作为
   *    格式提示一起返回，避免自动检测误判（QRC 解密后是 `[ms,dur]` 行，
   *    自动检测会掉进 LRC 分支从而解析失败）。
   *  - KRC 是二进制密文：这里就地解密，返回明文并显式标注 KRC 格式。
   */
  async loadLyricFor(track: Track): Promise<LyricPayload | undefined> {
    const path = track.localLyricPath;
    if (path === undefined || path.length === 0) {
      return undefined;
    }
    try {
      const extension = this.extensionOf(path);
      if (extension === 'krc') {
        const bytes = this.readBytes(path);
        const decrypted = decryptKrc(bytes);
        if (decrypted.trim().length === 0) {
          return undefined;
        }
        const payload: LyricPayload = {
          lyric: decrypted,
          pureMusic: false,
          source: 'local:krc',
          format: LyricFormat.KRC
        };
        return payload;
      }
      const text = this.readText(path);
      if (text.trim().length === 0) {
        return undefined;
      }
      const payload: LyricPayload = {
        lyric: text,
        pureMusic: false,
        source: `local:${extension}`,
        format: this.formatFromExtension(extension)
      };
      return payload;
    } catch (error) {
      Logger.err(TAG, `load lyric ${path}`, error as Error);
      return undefined;
    }
  }

  /** 侧车文件扩展名 -> 歌词格式；未知扩展名交给自动检测 */
  private formatFromExtension(extension: string): LyricFormat {
    switch (extension) {
      case 'vtt':
        return LyricFormat.VTT;
      case 'ttml':
        return LyricFormat.TTML;
      case 'yrc':
        return LyricFormat.YRC;
      case 'qrc':
        return LyricFormat.QRC;
      case 'krc':
        return LyricFormat.KRC;
      default:
        // .lrc 可能是标准 LRC 也可能是增强 LRC，交给自动检测更稳妥
        return LyricFormat.NONE;
    }
  }

  private readText(path: string): string {
    const stat = fileIo.statSync(path);
    const buffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0, length: stat.size });
    } finally {
      fileIo.closeSync(file);
    }
    // 本地歌词文件可能是 GBK，尝试 UTF-8 解码，失败则按 latin1 兜底
    const decoder = util.TextDecoder.create('utf-8', { fatal: false });
    return decoder.decodeToString(new Uint8Array(buffer));
  }

  private readBytes(path: string): Uint8Array {
    const stat = fileIo.statSync(path);
    const buffer = new ArrayBuffer(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      fileIo.readSync(file.fd, buffer, { offset: 0, length: stat.size });
    } finally {
      fileIo.closeSync(file);
    }
    return new Uint8Array(buffer);
  }

  // -------------------------------------------------------------------------
  // 持久化
  // -------------------------------------------------------------------------

  private loadIndex(): void {
    try {
      if (!fileIo.accessSync(this.indexPath)) {
        this.entries = [];
        this.rebuildTracks();
        return;
      }
      const text = this.readText(this.indexPath);
      if (text.trim().length === 0) {
        this.entries = [];
        this.rebuildTracks();
        return;
      }
      const index = JSON.parse(text) as LibraryIndex;
      this.entries = index.entries ?? [];
      // 启动时校验文件是否存在，剔除被外部删除的条目
      this.entries = this.entries.filter((e: LibraryEntry) => fileIo.accessSync(e.fileUri));
      this.rebuildTracks();
    } catch (error) {
      Logger.err(TAG, 'load index', error as Error);
      this.entries = [];
      this.rebuildTracks();
    }
  }

  private saveIndex(): void {
    const index: LibraryIndex = { version: 1, entries: this.entries };
    try {
      this.writeText(this.indexPath, JSON.stringify(index));
    } catch (error) {
      Logger.err(TAG, 'save index', error as Error);
    }
  }

  private rebuildTracks(): void {
    this.tracks = this.entries.map((e: LibraryEntry) => this.toTrack(e));
    this.loaded = true;
  }

  private toTrack(entry: LibraryEntry): Track {
    let cover: CoverRef | undefined = undefined;
    if (entry.coverPath !== undefined) {
      cover = { uri: entry.coverPath };
    }
    const track: Track = {
      id: entry.id,
      title: entry.title,
      artist: entry.artist,
      artists: entry.artists,
      album: entry.album,
      duration: entry.duration,
      origin: TrackOrigin.LOCAL,
      providerId: ProviderId.LOCAL,
      songId: entry.songId,
      cover: cover,
      fileUri: entry.fileUri,
      fileSize: entry.fileSize,
      localLyricPath: entry.localLyricPath,
      hasEmbeddedLyric: entry.hasEmbeddedLyric,
      addedAt: entry.addedAt
    };
    return track;
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  private extensionOf(path: string): string {
    const dot = path.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    return path.slice(dot + 1).toLowerCase();
  }

  private baseName(path: string): string {
    const slash = path.lastIndexOf('/');
    const name = slash >= 0 ? path.slice(slash + 1) : path;
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.slice(0, dot) : name;
  }

  /** 以 URI 生成稳定 id，同一文件多次导入得到同一 id */
  private hashKey(uri: string): string {
    let hash = 0;
    for (let i = 0; i < uri.length; i += 1) {
      hash = (hash * 31 + uri.charCodeAt(i)) | 0;
    }
    const positive = hash >>> 0;
    return positive.toString(16);
  }
}

export const localLibraryService: LocalLibraryService = new LocalLibraryService();
