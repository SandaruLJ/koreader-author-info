describe("reading time", function()
    local ReadingTime, SQ3, db

    before_each(function()
        package.loaded["authorinfo/reading_time"] = nil
        ReadingTime = require("authorinfo/reading_time")
        SQ3 = require("lua-ljsqlite3/init")
        db = os.tmpname()
        os.remove(db)
        local conn = SQ3.open(db)
        conn:exec([[
            CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text,
                md5 text, total_read_time integer);
            INSERT INTO book VALUES (NULL, 'Dune', 'Frank Herbert', 'aaa', 3600);
            INSERT INTO book VALUES (NULL, 'Dune (retitled)', 'Frank Herbert', 'aaa', 600);
            INSERT INTO book VALUES (NULL, 'Children of Dune', 'Frank Herbert', 'bbb', 1800);
            INSERT INTO book VALUES (NULL, 'Emma', 'Jane Austen', 'ccc', 900);
        ]])
        conn:close()
    end)

    after_each(function()
        os.remove(db)
    end)

    -- Files named after their saved fingerprint; "new" was never opened.
    local function md5(file) return file ~= "/new" and file:sub(2) or nil end

    it("sums every row of the books' saved fingerprints, each book once", function()
        assert.are.equal(6000, ReadingTime.seconds({ "/aaa", "/bbb", "/aaa", "/new" }, { db = db, md5 = md5 }))
        assert.are.equal(900, ReadingTime.seconds({ "/ccc" }, { db = db, md5 = md5 }))
    end)

    it("has nothing for unread books, or without the statistics database", function()
        assert.is_nil(ReadingTime.seconds({ "/new" }, { db = db, md5 = md5 }))
        assert.is_nil(ReadingTime.seconds({ "/ddd" }, { db = db, md5 = md5 }))
        assert.is_nil(ReadingTime.seconds({}, { db = db, md5 = md5 }))
        assert.is_nil(ReadingTime.seconds({ "/aaa" }, { db = db .. ".missing", md5 = md5 }))
    end)
end)
