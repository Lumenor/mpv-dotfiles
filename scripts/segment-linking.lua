--[[
    A script to implement support for matroska next/prev segment linking.
    Available at: https://github.com/CogentRedTester/mpv-segment-linking

    This is a different feature to ordered chapters, which mpv already supports natively.
    This script requires mkvinfo to be available in the system path.
]]--

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local opts = require "mp.options"

package.path = mp.command_native({"expand-path", "~~/script-modules/?.lua;"}) .. package.path
local RF_LOADED, rf = pcall(function() return require "read-file" end)

local o = {
    --loads segment information from the given segment metafile instead of scanning for it
    metafile = "",

    --if the current file cannot be read, then fallback to the default metafile
    fallback_to_metafile = true,

    --the default segment metafile file, the script will search for a file with this name inside
    --the directory of the current file
    default_metafile = ".segment-linking"
}

opts.read_options(o, "segment_linking", function() end)

local FLAG_CHAPTER_FIX

local ORDERED_CHAPTERS_ENABLED
local REFERENCES_ENABLED
local MERGE_THRESHOLD

--file extensions that support segment linking
local file_extensions = {
    mkv = true,
    mka = true
}

--decodes a URL address
--this piece of code was taken from: https://stackoverflow.com/questions/20405985/lua-decodeuri-luvit/20406960#20406960
local decodeURI
do
    local char, gsub, tonumber = string.char, string.gsub, tonumber
    local function _(hex) return char(tonumber(hex, 16)) end

    function decodeURI(s)
        s = gsub(s, '%%(%x%x)', _)
        return s
    end
end

--gets the directory section of the given path
local function get_directory(path)
    return path:match("^(.+[/\\])[^/\\]+[/\\]?$") or ""
end

--read contents of the given file
--tries to use the read-file module to support network files
local function open_file(file)
    if not RF_LOADED then return io.open(file) end
    return rf.get_file_handler(file)
end

--returns the uid of the given file, along with the previous and next uids if they exist.
--if fail_silent is true then do not print any error messages
local function get_uids(file, fail_silently)
    msg.debug("scanning UIDs for file", file)

    local cmd = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = {"mkvinfo", file}
    })

    if cmd.status ~= 0 then
        if not cmd.status then cmd.status = -1 end
        if fail_silently then return nil, nil, nil, cmd.status end
        msg.error("could not read file", file)
        msg.error(cmd.stdout)
        return nil, nil, nil, cmd.status
    end

    local output = cmd.stdout
    return  output:match("Segment UID: ([^\n\r]+)"),
            output:match("Previous segment UID: ([^\n\r]+)"),
            output:match("Next segment UID: ([^\n\r]+)")
end

--creates a UID table based on the input files
local function create_uid_table(files, directory)
    --go through the file list and populate the table
    local files_segments = {}
    for _, file in ipairs(files) do
        local file_ext = file:match("%.(%w+)$")

        if file_extensions[file_ext] then
            file = utils.join_path(directory,file)
            local uid, prev, next = get_uids(file)
            if uid ~= nil then
                files_segments[uid] = {
                    prev = prev,
                    next = next,
                    file = file
                }
            end
        end
    end

    return files_segments
end

--creates a uid table from the custom mpv-segment-linking file
local function create_table_segment_file(path, fail_silently)
    local file, err = open_file(path)
    if not file then return not fail_silently and msg.error(err) end

    local directory = get_directory(path)
    local header = file:read("*l")
    local contents = file:read("*a")
    file:close()

    local version = header:match("^# mpv%-segment%-linking v([.%d]+)")
    msg.verbose("loading segment file v"..version, ("%q"):format(path))

    local uid_table = {}
    local file_uids = {}

    for line in contents:gmatch("[^\n\r]+") do
        if (not line:find("^#") ) then
            local type, uid = line:match("^(%a+)=([%a%d ]+)$")
            if type == "UID" then
                uid_table[uid] = file_uids
            elseif type == "PREV" then
                file_uids.prev = uid;
            elseif type == "NEXT" then
                file_uids.next = uid
            else
                file_uids = {}
                file_uids.file = utils.join_path(directory, line)
            end
        end
    end

    return uid_table
end

--creates a table of UIDs based on the contents of the ordered-chapters-file playlist
--files must still be present on the local disk to scan for UIDs
local function create_table_ordered_chapters(ordered_chapters_files)
    local directory = get_directory(ordered_chapters_files)
    local pl, err = open_file(ordered_chapters_files)
    if not pl then return msg.error(err) end

    local files = {}
    for line in pl:lines() do
        --remove the newline character at the end of each line
        table.insert(files, line:match("[^\r\n]+"));
    end

    pl:close()
    return create_uid_table(files, directory)
end

--creates a table of available UIDs for the current file
local function create_table_filesystem(path)
    local directory = get_directory(path)
    local open_dir = directory ~= "" and directory or mp.get_property("working-directory", "")
    local files = utils.readdir(open_dir, "files")
    if not files then return msg.error("Could not read directory '"..open_dir.."'") end

    return create_uid_table(files, directory)
end

--returns the uids for the specified path from the table`
local function get_uids_from_table(path, uids)
    if not uids then return nil end
    for uid, t in pairs(uids) do
        if decodeURI(path) == decodeURI(t.file) then
            return uid, t.prev, t.next
        end
    end
end

--builds a timeline of linked segments for the current file
local function main()
    --we will respect these options just as ordered chapters do
    if not (ORDERED_CHAPTERS_ENABLED and REFERENCES_ENABLED) then return end

    local path = mp.get_property("stream-open-filename", "")
    local file_ext = path:match("%.(%w+)$")

    --if not a file that can contain segments then return
    if not file_extensions[file_ext] then return end

    local uid, prev, next
    local status, fallback

    if o.metafile ~= "" then
        uid, prev, next = get_uids_from_table(path, create_table_segment_file(o.metafile))
        if not uid then msg.error("Could not find matching segment UIDs for current file in '"..o.metafile.."'") ; return end
    else
        --read the uid info for the current file
        --if the file cannot be read, or if it does not contain next or prev uids, then return
        uid, prev, next, status = get_uids(path, true)
    end

    --a status of 2 is an open file error
    if o.fallback_to_metafile and (status == -1 or status == 2) then
        fallback = create_table_segment_file(get_directory(path)..o.default_metafile, true)
        uid, prev, next = get_uids_from_table(path, fallback)
    end

    if not uid then return end
    if not prev and not next then return end

    ------------------------------------------------------------------
    --------- Files without hard links will stop before here ---------
    ------------------------------------------------------------------

    msg.info("File uses linked segments, will build edit timeline.")

    local ordered_chapters_files = mp.get_property("ordered-chapters-files", "")

    --creates a table of available UIDs for the current file
    local segments

    if (fallback) then
        msg.info("Could not read file, will fallback to default segment-linking metafile")
        segments = fallback

    elseif (o.metafile ~= "") then
        msg.info("Loading segment info from '"..o.metafile.."'")
        segments = create_table_segment_file(o.metafile)

    elseif ordered_chapters_files ~= "" then
        msg.info("Loading references from '"..ordered_chapters_files.."'")
        segments = create_table_ordered_chapters(ordered_chapters_files)

    else
        msg.info("Will scan other files in the same directory to find referenced sources.")
        segments = create_table_filesystem(path)
    end

    if not segments then return msg.error("Aborting segment link.") end
    local list = {path}

    --adds the next and previous segment ids until reaching the end of the uid chain
    while (prev and segments[prev]) do
        msg.info("Match for previous segment:", segments[prev].file)
        table.insert(list, 1, segments[prev].file)
        prev = segments[prev].prev
    end

    while (next and segments[next]) do
        msg.info("Match for next segment:", segments[next].file)
        table.insert(list, segments[next].file)
        next = segments[next].next
    end

    --we'll use the mpv edl specification to merge the files into one seamless timeline
    local edl_path = "edl://"
    for _, segment in ipairs(list) do
        edl_path = edl_path..segment..",title=__mkv_segment;"
    end

    mp.set_property("stream-open-filename", edl_path)
    FLAG_CHAPTER_FIX = true
end

--[[
    Remove chapters added by the edl specification, with adjacent matching titles, or within the merge threshold.

    Segment linking does not have chapter generation as part of the specification and vlc does not do this, so we'll remove them all.

    If chapters are exactly equal to an existing chapter then it can make it impossible to seek backwards past the chapter
    unless we remove something, hence we'll merge chapters that are close together. Using the ordered-chapters merge option provides
    an easy way for people to customise this value, and further ties this script to the inbuilt ordered-chapters feature.

    Splitting chapters often results in the same chapter being present in both files, so we'll also merge adjacent chapters
    with the same chapter name. This is not part of the spec, but should provide a nice QOL change, with no downsides for encodes
    that avoid this issue.
]]--
local function fix_chapters()
    if not FLAG_CHAPTER_FIX then return end

    local chapters = mp.get_property_native("chapter-list", {})

    --remove chapters added by this script
    for i=#chapters, 1, -1 do
        if chapters[i].title == "__mkv_segment" then
            table.remove(chapters, i)
        end
    end

    --remove chapters with adjacent matching chapter names, which can happen when splitting segments
    --we want to do this pass separately to the threshold pass in case the end of a previous chapter falls
    --within the threshold of an actually new (named) chapter.
    for i = #chapters, 2, -1 do
        if chapters[i].title == chapters[i-1].title and chapters[i].title ~= "" then
            table.remove(chapters, i)
        end
    end

    --go over the chapters again and remove ones within the merge threshold
    for i = #chapters, 2, -1 do
        if chapters[i].time - chapters[i-1].time < MERGE_THRESHOLD then
            table.remove(chapters, i)
        end
    end

    mp.set_property_native("chapter-list", chapters)
    FLAG_CHAPTER_FIX = false
end

mp.add_hook("on_load", 50, main)
mp.add_hook("on_preloaded", 50, fix_chapters)

--monitor the relevant options
mp.observe_property("access-references", "bool", function(_, val) REFERENCES_ENABLED = val end)
mp.observe_property("ordered-chapters", "bool", function(_, val) ORDERED_CHAPTERS_ENABLED = val end)
mp.observe_property("chapter-merge-threshold", "number", function(_, val) MERGE_THRESHOLD = val/1000 end)
