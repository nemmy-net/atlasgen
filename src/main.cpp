#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string_view>
#include <optional>
#include <filesystem>
#include <unordered_map>
#include <map>
#include <chrono>
#include <fstream>

#include <freetype/freetype.h>
#include <freetype/ftmm.h>
#include <png.h>
#include "defer.hpp"

#define STB_RECT_PACK_IMPLEMENTATION
#include <stb_rect_pack.h>

void CheckFtErr(FT_Error err) {
    if (err != FT_Err_Ok) {
        printf("FT_Error %d (%s)\n", err, FT_Error_String(err));
        exit(-1);
    }
}

class ArgIter {
    int m_argc;
    char** m_argv;
    int m_index = 1;

public:
    ArgIter(int argc, char** argv) {
        this->m_argc = argc;
        this->m_argv = argv;
    }

    bool Match(std::string_view str) {
        if (m_index < m_argc && std::string_view{m_argv[m_index]} == str) {
            ++m_index;
            return true;
        }
        return false;
    }

    std::optional<std::string_view> Next() {
        if (m_index >= m_argc) {
            return {};
        }
        ++m_index;
        return {std::string_view{m_argv[m_index-1]}};
    }
};

template <class T>
std::optional<T> ParseInt(std::optional<std::string_view> str_) {
    if (!str_) {
        return {};
    }
    const auto& str = str_.value();

    T i = 0;
    for (char ch : str) {
        if (ch < '0' && ch > '9') {
            return {};
        }
        i *= 10;
        i += ch - '0';
    }
    return i;
}

template <class T>
std::optional<T> ParseFloat(std::optional<std::string_view> str_) {
    if (!str_) {
        return {};
    }
    const auto& str = str_.value();

    size_t i = 0;
    uint64_t num = 0;
    for (; i < str.length(); ++i) {
        if (str[i] < '0' || str[i] > '9') {
            break;
        }
        num *= 10;
        num += str[i] - '0';
    }
    if (i >= str.length()) {
        return (T)num;
    } else if (str[i] != '.') {
        return {};
    }
    ++i;
    uint64_t denom = 0, div = 1;
    for (; i < str.length(); ++i) {
        if (str[i] < '0' || str[i] > '9') {
            return {};
        }
        denom *= 10;
        denom += str[i] - '0';
        div *= 10;
    }
    return (T)num + (T)denom / (T)div;
}

struct GlyphData {
    size_t rectIndex;
    FT_UInt glyphIndex;
    unsigned int width;
    unsigned int height;
    FT_Int leftBearing;
    FT_Int topBearing;
    FT_Pos advance;
};

int main(int argc, char** argv) {
    auto timeBegin = std::chrono::high_resolution_clock::now();

    FT_Library ft;
    CheckFtErr(FT_Init_FreeType(&ft));
    defer { FT_Done_FreeType(ft); };

    ArgIter args{argc, argv};
    std::optional<std::string_view> fontPath, outDir;
    int desiredSize = 16;
    // Array of first-last codepoint ranges.
    std::vector<std::pair<uint32_t, uint32_t>> cpRanges;
    std::unordered_map<std::string, FT_Fixed> axes;
    bool mono = false;

    while (auto flag = args.Next()) {
        if (flag == "--font") {
            fontPath = args.Next();
            if (!fontPath) {
                printf("expected --font <path>\n");
                return -1;
            }
        } else if (flag == "--out") {
            outDir = args.Next();
            if (!outDir) {
                printf("expected --out <path>\n");
                return -1;
            }
        } else if (flag == "--size") {
            std::optional<int> size = ParseInt<int>(args.Next());
            if (!size) {
                printf("expected --size <int>\n");
                return -1;
            }
            desiredSize = size.value();
        } else if (flag == "--range") {
            auto first = ParseInt<uint32_t>(args.Next());
            auto last = ParseInt<uint32_t>(args.Next());
            if (!first || !last) {
                printf("expected --range <int> <int>\n");
                return -1;
            }

            if (*first >= *last) {
                printf("Invalid range. Right value must be larger than left value.\n");
                return -1;
            }
            cpRanges.push_back({*first, *last});
        } else if (flag == "--axis") {
            auto name = args.Next();
            auto value = ParseFloat<double>(args.Next());
            if (!name || !value) {
                printf("Expected --axis <name> <float>\n");
                return -1;
            }
            axes.emplace(*name, (FT_Fixed)(*value * (1<<16)));
        } else if (flag == "--mono") {
            mono = true;
        } else {
            printf("Unknown flag: %s\n", flag->data());
            return -1;
        }
    }

    if (!fontPath || !outDir) {
        printf("--font and --out must be set\n");
        return -1;
    }

    FT_Face face;
    CheckFtErr(FT_New_Face(ft, fontPath->data(), 0, &face));
    defer { FT_Done_Face(face); };
    CheckFtErr(FT_Set_Pixel_Sizes(face, 0, desiredSize));

    if (!axes.empty()) {
        FT_MM_Var* master;
        CheckFtErr(FT_Get_MM_Var(face, &master));
        defer { FT_Done_MM_Var(ft, master); };

        if (master->num_axis == 0) {
            printf("This font has no axes\n");
            return -1;
        }

        std::vector<FT_Fixed> coords;
        coords.reserve(master->num_axis);
        for (FT_UInt i = 0; i < master->num_axis; ++i) {
            const FT_Var_Axis& axis = master->axis[i];
            FT_Fixed coord = axis.def;
            auto it = axes.find(axis.name);
            if (it != axes.end()) {
                coord = it->second;
                axes.erase(it);
            }

            if (coord < axis.minimum || coord > axis.maximum) {
                printf("Axis %s must be %f <= x <= %f\n", axis.name, (double)axis.minimum / (1 << 16), (double)axis.maximum / (1 << 16));
                return -1;
            }
            coords.push_back(coord);
        }

        if (!axes.empty()) {
            printf("The provided axis/axes do not exist in this font:");
            for (auto it = axes.begin(); it != axes.end(); ++it) {
                printf("%s%s", it == axes.begin() ? " " : ", ", it->first.c_str());
            }
            printf("\nValid axes are:");
            for (FT_UInt i = 0; i < master->num_axis; ++i) {
                printf("%s%s", i == 0 ? " " : ", ", master->axis[i].name);
            }
            printf("\n");
            return -1;
        }

        CheckFtErr(FT_Set_Var_Design_Coordinates(face, coords.size(), coords.data()));
    }

    if (cpRanges.empty()) {
        FT_UInt glyphIndex;
        FT_ULong firstChar = FT_Get_First_Char(face, &glyphIndex);
        FT_ULong lastChar = firstChar;
        if (firstChar == 0) {
            printf("Font has no charmap\n");
            return -1;
        }

        while (FT_ULong nextChar = FT_Get_Next_Char(face, lastChar, &glyphIndex)) {
            if (nextChar != lastChar+1) {
                cpRanges.push_back({firstChar, lastChar});
                firstChar = nextChar;
            }
            lastChar = nextChar;
        }

        cpRanges.push_back({firstChar, lastChar});
    }
    
    std::map<FT_UInt, GlyphData> glyphs;
    std::vector<stbrp_rect> rects;
    uint32_t totalW = 0, totalH = 0;

    const uint32_t RECT_PAD = 1;
    for (auto range : cpRanges) {
        for (uint32_t cp = range.first; cp <= range.second; ++cp) {
            FT_UInt glyphIndex = FT_Get_Char_Index(face, cp);
    
            auto insertion = glyphs.try_emplace(glyphIndex, GlyphData{});
            if (!insertion.second) {
                continue; // We already store this glyph
            }
            CheckFtErr(FT_Load_Glyph(face, glyphIndex, FT_LOAD_DEFAULT));
            auto& glyph = insertion.first->second;
            glyph.rectIndex = (size_t)-1;
            glyph.glyphIndex = glyphIndex;
            glyph.width = face->glyph->bitmap.width;
            glyph.height = face->glyph->bitmap.rows;
            glyph.leftBearing = face->glyph->bitmap_left;
            glyph.topBearing = face->glyph->bitmap_top;
            glyph.advance = face->glyph->advance.x;

            if (glyph.width * glyph.height != 0) {
                totalW += glyph.width;
                totalH += glyph.height;
                stbrp_rect rect;
                memset(&rect, 0, sizeof(rect));
                rect.w = glyph.width + RECT_PAD*2;
                rect.h = glyph.height + RECT_PAD*2;
                rects.push_back(rect);
                glyph.rectIndex = rects.size()-1;
            }
        }
    }

    
    int atlasW = 0;
    int atlasH = 0;
    {
        stbrp_context rpc;
        const float RP_GROWTH = 1.2f;
        int targetW = sqrt(totalW);
        int targetH = sqrt(totalH);
        std::vector<stbrp_node> rpNodes{(size_t)targetW * 2};
        while (true) {
            stbrp_init_target(&rpc, targetW, targetH, rpNodes.data(), rpNodes.size());
            if (stbrp_pack_rects(&rpc, rects.data(), rects.size())) {
                break;
            }
            targetW *= RP_GROWTH;
            targetH *= RP_GROWTH;
            rpNodes.resize(targetW);
        }
        for (auto& rect : rects) {
            if (rect.x + rect.w > atlasW)
                atlasW = rect.x + rect.w;
            if (rect.y + rect.h > atlasH)
                atlasH = rect.y + rect.h;
        }
    }


    std::vector<uint8_t> atlasBmp;
    const size_t atlasChannels = 1;
    const size_t atlasPitch = atlasW * atlasChannels;
    atlasBmp.resize(atlasW * atlasH * atlasChannels);
    memset(atlasBmp.data(), 0, atlasBmp.size());
    for (auto& pair : glyphs) {
        auto& glyph = pair.second;
        if (glyph.rectIndex == (size_t)-1) {
            continue;
        }

        CheckFtErr(FT_Load_Glyph(face, glyph.glyphIndex, FT_LOAD_DEFAULT));
        if (face->glyph->format != FT_GLYPH_FORMAT_BITMAP) {
            CheckFtErr(FT_Render_Glyph(face->glyph, mono ? FT_RENDER_MODE_MONO : FT_RENDER_MODE_LIGHT));
        }

        stbrp_rect& rect = rects[glyph.rectIndex];
        // Remove padding
        rect.x += RECT_PAD, rect.y += RECT_PAD;
        rect.w -= RECT_PAD*2, rect.h -= RECT_PAD*2;

        int channels = 0;
        const unsigned char* buffer = face->glyph->bitmap.buffer;
        switch (face->glyph->bitmap.pixel_mode) {
        case FT_PIXEL_MODE_GRAY: {
            // Convert to GA
            int src_channels = 1;
            int src_pitch = abs(face->glyph->bitmap.pitch);
            for (unsigned int y = 0; y < face->glyph->bitmap.rows; ++y) {
                for (unsigned int x = 0; x < face->glyph->bitmap.width; ++x) {
                    const unsigned char* src = &buffer[x*src_channels + y*src_pitch];
                    unsigned char* dst = &atlasBmp[(x + rect.x)*atlasChannels + (y+rect.y)*atlasPitch];
                    dst[0] = src[0];
                }
            }
            break;
        }
        case FT_PIXEL_MODE_MONO: {
            int src_pitch = abs(face->glyph->bitmap.pitch);
            for (unsigned int y = 0; y < face->glyph->bitmap.rows; ++y) {
                for (unsigned int x = 0; x < face->glyph->bitmap.width; ++x) {
                    const unsigned char* src = &buffer[(x/8) + y*src_pitch];
                    unsigned char* dst = &atlasBmp[(x + rect.x)*atlasChannels + (y+rect.y)*atlasPitch];
                    dst[0] = ((src[0] >> (7 - (x%8))) & 1) * 0xFF;
                }
            }
            break;
        }
        case FT_PIXEL_MODE_BGRA:
        case FT_PIXEL_MODE_NONE:
        case FT_PIXEL_MODE_LCD:
        case FT_PIXEL_MODE_LCD_V:
        case FT_PIXEL_MODE_GRAY2:
        case FT_PIXEL_MODE_GRAY4:
            printf("Unsupported FT_Pixel_Mode %d\n", face->glyph->bitmap.pixel_mode);
            return -1;
        default:
            printf("Unknown FT_Pixel_Mode %d\n", face->glyph->bitmap.pixel_mode);
            return -1;
        }
    }

    std::filesystem::create_directory(*outDir);
    auto outAtlas = std::filesystem::path{*outDir} / "atlas.png";
    auto outMap = std::filesystem::path{*outDir} / "map.json";

    png_image png;
    memset(&png, 0, sizeof(png));
    png.version = PNG_IMAGE_VERSION;
    png.width = atlasW;
    png.height = atlasH;
    png.format = PNG_FORMAT_GRAY;
    int code = png_image_write_to_file(&png, outAtlas.string().c_str(), 0, atlasBmp.data(), atlasPitch, nullptr);
    if (code != 1) {
        printf("Failed to write PNG file (%d)\n", code);
        return -1;
    }

    std::fstream f{outMap, std::ios::out};
    if (!f.is_open()) {
        printf("Failed to write map to %s\n", outMap.string().c_str());
        return -1;
    }
    
    f << '{';
    f << "\"version\":1,";
    f << "\"glyphs\":[";
    std::unordered_map<FT_UInt, size_t> glyphIdToJsonId;
    {
        size_t nextJsonId = 0;
        GlyphData prevGlyph;
        int prevRectX = 0, prevRectY = 0;
        memset(&prevGlyph, 0, sizeof(prevGlyph));
        // Glyph structs flattened into one number array and delta-encoded.
        // Will be parsed as `{width, height, leftBearing, topBearing, advance, x, y}`
        for (auto& pair : glyphs) {
            if (nextJsonId != 0) {
                f << ',';
            }
            auto& glyph = pair.second;
            glyphIdToJsonId[glyph.glyphIndex] = nextJsonId;
            f << (int64_t)glyph.width - (int64_t)prevGlyph.width << ',';
            f << (int64_t)glyph.height - (int64_t)prevGlyph.height << ',';
            f << (int64_t)glyph.leftBearing - (int64_t)prevGlyph.leftBearing << ',';
            f << (int64_t)glyph.topBearing - (int64_t)prevGlyph.topBearing << ',';
            f << (((int64_t)glyph.advance - (int64_t)prevGlyph.advance) >> 6) << ',';
            int rectX = 0, rectY = 0;
            if (glyph.rectIndex != (size_t)-1) {
                auto& rect = rects[glyph.rectIndex];
                rectX = rect.x, rectY = rect.y;
            }
            f << (rectX - prevRectX) << ',';
            f << (rectY - prevRectY);
            prevGlyph = glyph;
            prevRectX = rectX;
            prevRectY = rectY;
            ++nextJsonId;
        }
    }
    f << "],\"codepoints\":[";
    // Pairs of [codepoint, glyphJsonId] flattened into one number array and delta-encoded.
    {
        size_t i = 0;
        uint32_t lastCp = 0;
        uint32_t lastGlyphJsonId = 0;
        for (auto cpRange : cpRanges) {
            for (uint32_t cp = cpRange.first; cp <= cpRange.second; ++cp, ++i) {
                FT_UInt glyphIndex = FT_Get_Char_Index(face, cp);
                if (glyphIndex == 0) {
                    continue;
                }
                size_t glyphJsonId = glyphIdToJsonId[glyphIndex];
                if (i != 0) {
                    f << ',';
                }
                f << (int64_t)cp - (int64_t)lastCp << ',' << (int64_t)glyphJsonId - (int64_t)lastGlyphJsonId;
                lastGlyphJsonId = glyphJsonId;
                lastCp = cp;
            }
        }
    }
    f << "],\"metrics\":{";
    f << "\"ascender\":" << (face->size->metrics.ascender >> 6) << ",";
    f << "\"descender\":" << (face->size->metrics.descender >> 6) << ",";
    f << "\"height\":" << (face->size->metrics.height >> 6);
    f << "}";
    f << '}';
    f.close();

    auto timeEnd = std::chrono::high_resolution_clock::now();
    printf("Completed in %f ms\n", (double)std::chrono::duration_cast<std::chrono::microseconds>(timeEnd-timeBegin).count() / 1000.0);

    return 0;
}